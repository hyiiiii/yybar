//! Claude access_token 续期（对应 Mac `ClaudeTokenRefresher`）。
//!
//! Claude 的 refresh_token 是一次性的：每次刷新服务端都会换一个新值，旧值立即作废。
//! 用户同时开着 Claude Code / Claude Desktop / cc-switch 时谁先刷新成功，别人手里的就变成 invalid_grant。
//! 所以 yybar 把自己当只读监控，「被动优先」：
//! 1. skew 只有 30 秒，临期主动刷新让给 CLI；
//! 2. 进程内串行 + 去重（`LOCK`），几个入口同时触发只刷新一次；
//! 3. 拿锁后先重读凭据文件：别人刚写入新鲜 token 就直接用，不发请求；refresh_token 被换过就用新的；
//! 4. 文件 10 秒内被改过，认为别人刚刷新完，等 1 秒再重读；
//! 5. 服务端回 invalid_grant 时等 1 秒再重读，有新值就静默采用，不报错。
//! Mac 版第 6 步「委托本机 claude CLI 代办刷新」Windows 上没有做：失败时提示用户在终端运行 claude。

use std::path::Path;
use std::time::Duration;

use serde_json::{Map, Value};
use tokio::sync::Mutex;

use super::{client, QuotaError};
use crate::credentials::{claude, ClaudeAccount};
use crate::paths;

pub const CLIENT_ID: &str = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
pub const TOKEN_ENDPOINT: &str = "https://platform.claude.com/v1/oauth/token";
pub const REFRESH_SKEW: i64 = 30;
const POLITE_MTIME_WINDOW: u64 = 10;
const SOFT_RECOVERY_DELAY: Duration = Duration::from_secs(1);

static LOCK: Mutex<()> = Mutex::const_new(());

struct Stored {
    access: String,
    refresh: Option<String>,
    expires_at: Option<i64>,
}

pub fn is_expired(expires_at: Option<i64>, skew: i64, now: i64) -> bool {
    expires_at.is_some_and(|e| e - now < skew)
}

/// 需要时续期并更新 `account`。返回当前可用的 access_token。
pub async fn ensure_fresh(account: &mut ClaudeAccount) -> Result<String, QuotaError> {
    let current = account.access_token.clone().ok_or(QuotaError::MissingToken)?;
    if !is_expired(account.expires_at, REFRESH_SKEW, crate::now_secs()) {
        return Ok(current);
    }
    let mut refresh = account
        .refresh_token
        .clone()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| QuotaError::TokenRefreshFailed("no refresh_token".into()))?;
    let _guard = LOCK.lock().await;
    let path = account.path.clone();

    // 拿锁后先重读：别人可能已经刷新并写回了。
    if let Some(fresh) = adopt_or_update(&path, &mut refresh) {
        return Ok(apply(account, fresh));
    }
    // 文件刚被改过：礼让一拍再重读。
    if modified_recently(&path) {
        tokio::time::sleep(SOFT_RECOVERY_DELAY).await;
        if let Some(fresh) = adopt_or_update(&path, &mut refresh) {
            return Ok(apply(account, fresh));
        }
    }
    match network_refresh(&refresh).await {
        Ok(fresh) => {
            write_back(&path, &fresh)?;
            Ok(apply(account, fresh))
        }
        Err(QuotaError::TokenRevoked) => {
            // 软恢复：别人可能就在这几百毫秒里用旧 refresh_token 抢先刷新成功。
            tokio::time::sleep(SOFT_RECOVERY_DELAY).await;
            if let Some(stored) = peek(&path) {
                if stored.refresh.as_deref().is_some_and(|r| r != refresh)
                    && stored.expires_at.is_some()
                    && !is_expired(stored.expires_at, 0, crate::now_secs())
                {
                    return Ok(apply(account, stored));
                }
            }
            Err(QuotaError::TokenRevoked)
        }
        Err(e) => Err(e),
    }
}

fn apply(account: &mut ClaudeAccount, fresh: Stored) -> String {
    account.access_token = Some(fresh.access.clone());
    if fresh.refresh.is_some() {
        account.refresh_token = fresh.refresh;
    }
    account.expires_at = fresh.expires_at;
    fresh.access
}

/// 存储里已经是新鲜 token 就返回它；否则把 refresh 换成存储里最新的一份。
fn adopt_or_update(path: &Path, refresh: &mut String) -> Option<Stored> {
    let stored = peek(path)?;
    if stored.expires_at.is_some() && !is_expired(stored.expires_at, REFRESH_SKEW, crate::now_secs()) {
        return Some(stored);
    }
    if let Some(r) = stored.refresh.filter(|r| !r.is_empty()) {
        *refresh = r;
    }
    None
}

fn peek(path: &Path) -> Option<Stored> {
    let root: Value = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    let oauth = root.get("claudeAiOauth")?;
    let access = oauth.get("accessToken").or_else(|| oauth.get("access_token"))?.as_str()?.to_string();
    if access.is_empty() {
        return None;
    }
    Some(Stored {
        access,
        refresh: oauth.get("refreshToken").or_else(|| oauth.get("refresh_token")).and_then(Value::as_str).map(str::to_string),
        expires_at: claude::parse_expiry(oauth.get("expiresAt")),
    })
}

fn modified_recently(path: &Path) -> bool {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|m| m.elapsed().ok())
        .is_some_and(|age| age.as_secs() < POLITE_MTIME_WINDOW)
}

async fn network_refresh(refresh: &str) -> Result<Stored, QuotaError> {
    let resp = client()
        .post(TOKEN_ENDPOINT)
        .header("Accept", "application/json")
        .form(&[("grant_type", "refresh_token"), ("refresh_token", refresh), ("client_id", CLIENT_ID)])
        .send()
        .await
        .map_err(|e| QuotaError::TokenRefreshFailed(format!("transport: {e}")))?;
    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        if status.as_u16() == 400 && body.contains("invalid_grant") {
            return Err(QuotaError::TokenRevoked);
        }
        return Err(QuotaError::TokenRefreshFailed(format!("http {}: {}", status.as_u16(), body)));
    }
    let root: Value = serde_json::from_str(&body).map_err(|_| QuotaError::TokenRefreshFailed("invalid json".into()))?;
    let access = root
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or_else(|| QuotaError::TokenRefreshFailed("no access_token in response".into()))?
        .to_string();
    let expires_in = root.get("expires_in").and_then(Value::as_f64).unwrap_or(3600.0) as i64;
    Ok(Stored {
        access,
        refresh: Some(root.get("refresh_token").and_then(Value::as_str).unwrap_or(refresh).to_string()),
        expires_at: Some(crate::now_secs() + expires_in),
    })
}

fn write_back(path: &Path, fresh: &Stored) -> Result<(), QuotaError> {
    let mut root: Map<String, Value> = std::fs::read(path)
        .ok()
        .and_then(|d| serde_json::from_slice(&d).ok())
        .unwrap_or_default();
    let mut oauth = root.get("claudeAiOauth").and_then(Value::as_object).cloned().unwrap_or_default();
    oauth.insert("accessToken".into(), fresh.access.clone().into());
    if let Some(r) = &fresh.refresh {
        oauth.insert("refreshToken".into(), r.clone().into());
    }
    // CLI 用毫秒时间戳
    if let Some(e) = fresh.expires_at {
        oauth.insert("expiresAt".into(), (e * 1000).into());
    }
    root.insert("claudeAiOauth".into(), Value::Object(oauth));
    let data = serde_json::to_vec_pretty(&root).map_err(|e| QuotaError::TokenRefreshFailed(e.to_string()))?;
    paths::write_atomic(path, &data).map_err(|e| QuotaError::TokenRefreshFailed(format!("write credentials: {e}")))
}
