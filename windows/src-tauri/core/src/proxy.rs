//! 代理：reqwest 自己会读 Windows「手动设置代理」（Internet 选项里的代理服务器）和 HTTPS_PROXY 环境变量，
//! 但不认「使用设置脚本」（PAC，AutoConfigURL）。不少代理工具的 PAC 模式只设了脚本地址，这时浏览器走代理、
//! yybar 直连，国内连 workers.dev 之类就会失败（「error sending request」）。
//!
//! 系统设置里有脚本地址时，用 WinHTTP 按每个请求的地址算出代理（结果按主机缓存 10 分钟）；没有脚本地址时什么也不做，
//! 照旧用 reqwest 读到的手动代理。不做「自动检测设置」（WPAD）：很多电脑默认开着，检测不到时每个新主机都要等几秒。

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const CACHE_FOR: Duration = Duration::from_secs(600);

/// 系统设置了代理脚本（PAC）时，按脚本给每个请求选代理的 reqwest 代理；没设置时为 None。
pub fn pac_proxy() -> Option<reqwest::Proxy> {
    let script = pac_script_url()?;
    let cache: Mutex<HashMap<String, (Instant, Option<String>)>> = Mutex::new(HashMap::new());
    Some(reqwest::Proxy::custom(move |url| {
        let host = url.host_str()?.to_string();
        if let Some((at, proxy)) = cache.lock().unwrap().get(&host) {
            if at.elapsed() < CACHE_FOR {
                return proxy.clone();
            }
        }
        let proxy = resolve(&script, url.as_str()).and_then(|list| pick(&list, url.scheme())).map(|p| format!("http://{p}"));
        cache.lock().unwrap().insert(host, (Instant::now(), proxy.clone()));
        proxy
    }))
}

/// WinHTTP 给的代理列表（`host:port;host2:port`，或分协议的 `http=a:1;https=b:2`）里取这个协议该用的第一个。
fn pick(list: &str, scheme: &str) -> Option<String> {
    let items: Vec<&str> = list.split([';', ' ']).map(str::trim).filter(|s| !s.is_empty()).collect();
    let tagged = items.iter().find_map(|s| s.strip_prefix(&format!("{scheme}=")));
    tagged.or_else(|| items.iter().copied().find(|s| !s.contains('='))).map(str::to_string)
}

#[cfg(windows)]
fn pac_script_url() -> Option<String> {
    win::ie_config_script()
}

#[cfg(not(windows))]
fn pac_script_url() -> Option<String> {
    None
}

#[cfg(windows)]
fn resolve(script: &str, url: &str) -> Option<String> {
    win::proxy_for_url(script, url)
}

#[cfg(not(windows))]
fn resolve(_script: &str, _url: &str) -> Option<String> {
    None
}

#[cfg(windows)]
mod win {
    use windows_sys::core::PWSTR;
    use windows_sys::Win32::Foundation::GlobalFree;
    use windows_sys::Win32::Networking::WinHttp::{
        WinHttpCloseHandle, WinHttpGetIEProxyConfigForCurrentUser, WinHttpGetProxyForUrl, WinHttpOpen, WINHTTP_ACCESS_TYPE_NAMED_PROXY,
        WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_AUTOPROXY_CONFIG_URL, WINHTTP_AUTOPROXY_OPTIONS, WINHTTP_CURRENT_USER_IE_PROXY_CONFIG, WINHTTP_PROXY_INFO,
    };

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    /// 读出 WinHTTP 分配的字符串并释放。
    unsafe fn take(p: PWSTR) -> Option<String> {
        if p.is_null() {
            return None;
        }
        let len = (0..).take_while(|&i| *p.add(i) != 0).count();
        let s = String::from_utf16_lossy(std::slice::from_raw_parts(p, len));
        GlobalFree(p as _);
        Some(s).filter(|s| !s.trim().is_empty())
    }

    /// 当前用户 Internet 选项里「使用设置脚本」的地址。
    pub fn ie_config_script() -> Option<String> {
        unsafe {
            let mut c: WINHTTP_CURRENT_USER_IE_PROXY_CONFIG = std::mem::zeroed();
            if WinHttpGetIEProxyConfigForCurrentUser(&mut c) == 0 {
                return None;
            }
            let script = take(c.lpszAutoConfigUrl);
            take(c.lpszProxy);
            take(c.lpszProxyBypass);
            script
        }
    }

    /// 按代理脚本算这个地址的代理列表；脚本说直连或出错时为 None。
    pub fn proxy_for_url(script: &str, url: &str) -> Option<String> {
        unsafe {
            let agent = wide("yybar");
            let session = WinHttpOpen(agent.as_ptr(), WINHTTP_ACCESS_TYPE_NO_PROXY, std::ptr::null(), std::ptr::null(), 0);
            if session.is_null() {
                return None;
            }
            let script = wide(script);
            let target = wide(url);
            let mut options: WINHTTP_AUTOPROXY_OPTIONS = std::mem::zeroed();
            options.dwFlags = WINHTTP_AUTOPROXY_CONFIG_URL;
            options.lpszAutoConfigUrl = script.as_ptr();
            options.fAutoLogonIfChallenged = 1;
            let mut info: WINHTTP_PROXY_INFO = std::mem::zeroed();
            let ok = WinHttpGetProxyForUrl(session, target.as_ptr(), &mut options, &mut info) != 0;
            let proxy = take(info.lpszProxy);
            take(info.lpszProxyBypass);
            WinHttpCloseHandle(session);
            proxy.filter(|_| ok && info.dwAccessType == WINHTTP_ACCESS_TYPE_NAMED_PROXY)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_the_proxy_for_the_scheme() {
        assert_eq!(pick("127.0.0.1:7890", "https").as_deref(), Some("127.0.0.1:7890"));
        assert_eq!(pick("127.0.0.1:7890; 10.0.0.1:8080", "https").as_deref(), Some("127.0.0.1:7890"));
        assert_eq!(pick("http=a:1;https=b:2", "https").as_deref(), Some("b:2"));
        assert_eq!(pick("http=a:1", "https"), None);
        assert_eq!(pick("", "https"), None);
    }
}
