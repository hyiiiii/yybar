//! 只读 SQLite 的最小封装：运行时加载系统自带的库（Windows 10+ 的 `winsqlite3.dll`，
//! 其他系统的 `libsqlite3`），不随 App 编译 SQLite 的 C 源码。只实现读 agy 会话库用到的几个函数。

use std::ffi::{c_char, c_int, c_void, CString};
use std::path::Path;
use std::sync::OnceLock;

type Db = *mut c_void;
type Stmt = *mut c_void;

const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_OPEN_READWRITE: c_int = 0x02;
const SQLITE_OPEN_CREATE: c_int = 0x04;

struct Api {
    _lib: libloading::Library,
    open_v2: unsafe extern "C" fn(*const c_char, *mut Db, c_int, *const c_char) -> c_int,
    close: unsafe extern "C" fn(Db) -> c_int,
    prepare_v2: unsafe extern "C" fn(Db, *const c_char, c_int, *mut Stmt, *mut *const c_char) -> c_int,
    step: unsafe extern "C" fn(Stmt) -> c_int,
    finalize: unsafe extern "C" fn(Stmt) -> c_int,
    column_count: unsafe extern "C" fn(Stmt) -> c_int,
    column_int64: unsafe extern "C" fn(Stmt, c_int) -> i64,
    column_blob: unsafe extern "C" fn(Stmt, c_int) -> *const c_void,
    column_bytes: unsafe extern "C" fn(Stmt, c_int) -> c_int,
    exec: unsafe extern "C" fn(Db, *const c_char, *const c_void, *const c_void, *mut *mut c_char) -> c_int,
}

fn api() -> Option<&'static Api> {
    static API: OnceLock<Option<Api>> = OnceLock::new();
    API.get_or_init(|| unsafe { load() }).as_ref()
}

unsafe fn load() -> Option<Api> {
    let names: &[&str] = if cfg!(windows) {
        &["winsqlite3.dll", "sqlite3.dll"]
    } else if cfg!(target_os = "macos") {
        &["libsqlite3.dylib"]
    } else {
        &["libsqlite3.so.0", "libsqlite3.so"]
    };
    let lib = names.iter().find_map(|n| libloading::Library::new(n).ok())?;
    macro_rules! sym {
        ($name:literal) => {
            *lib.get($name).ok()?
        };
    }
    Some(Api {
        open_v2: sym!(b"sqlite3_open_v2\0"),
        close: sym!(b"sqlite3_close\0"),
        prepare_v2: sym!(b"sqlite3_prepare_v2\0"),
        step: sym!(b"sqlite3_step\0"),
        finalize: sym!(b"sqlite3_finalize\0"),
        column_count: sym!(b"sqlite3_column_count\0"),
        column_int64: sym!(b"sqlite3_column_int64\0"),
        column_blob: sym!(b"sqlite3_column_blob\0"),
        column_bytes: sym!(b"sqlite3_column_bytes\0"),
        exec: sym!(b"sqlite3_exec\0"),
        _lib: lib,
    })
}

pub fn available() -> bool {
    api().is_some()
}

pub struct Connection {
    db: Db,
}

impl Connection {
    /// 打开（已复制出来的）库。`create` 只给测试用。
    pub fn open(path: &Path, create: bool) -> Option<Connection> {
        let api = api()?;
        let c_path = CString::new(path.to_string_lossy().as_bytes()).ok()?;
        let mut db: Db = std::ptr::null_mut();
        let flags = SQLITE_OPEN_READWRITE | if create { SQLITE_OPEN_CREATE } else { 0 };
        let rc = unsafe { (api.open_v2)(c_path.as_ptr(), &mut db, flags, std::ptr::null()) };
        if rc != SQLITE_OK {
            if !db.is_null() {
                unsafe { (api.close)(db) };
            }
            return None;
        }
        Some(Connection { db })
    }

    pub fn exec(&self, sql: &str) -> bool {
        let Some(api) = api() else { return false };
        let Ok(c_sql) = CString::new(sql) else { return false };
        unsafe { (api.exec)(self.db, c_sql.as_ptr(), std::ptr::null(), std::ptr::null(), std::ptr::null_mut()) == SQLITE_OK }
    }

    /// 逐行回调：(第一列整数（只有一列时为 0）, 最后一列 blob)。
    pub fn for_each_blob(&self, sql: &str, mut body: impl FnMut(i64, &[u8])) -> bool {
        let Some(api) = api() else { return false };
        let Ok(c_sql) = CString::new(sql) else { return false };
        let mut stmt: Stmt = std::ptr::null_mut();
        let rc = unsafe { (api.prepare_v2)(self.db, c_sql.as_ptr(), -1, &mut stmt, std::ptr::null_mut()) };
        if rc != SQLITE_OK || stmt.is_null() {
            return false;
        }
        unsafe {
            let blob_col = (api.column_count)(stmt) - 1;
            while (api.step)(stmt) == SQLITE_ROW {
                let idx = if blob_col > 0 { (api.column_int64)(stmt, 0) } else { 0 };
                let count = (api.column_bytes)(stmt, blob_col);
                let ptr = (api.column_blob)(stmt, blob_col);
                if count <= 0 || ptr.is_null() {
                    continue;
                }
                body(idx, std::slice::from_raw_parts(ptr as *const u8, count as usize));
            }
            (api.finalize)(stmt);
        }
        true
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        if let Some(api) = api() {
            unsafe { (api.close)(self.db) };
        }
    }
}
