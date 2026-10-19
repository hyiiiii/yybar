// Release 构建不弹控制台窗口
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    yybar_lib::run()
}
