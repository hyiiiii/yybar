//! Codex access_token 续期（对应 Mac `CodexTokenRefresher`）：JWT `exp` 剩余不到 5 分钟时用 refresh_token 续期，
//! 成功后原子写回原来的 auth.json（保留其他字段）。

use std::path::Path;

use serde_json::{Map, Value};

use super::{client, QuotaError};
use crate::credentials::{jwt, CodexAccount};
use crate::paths;

pub const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const TOKEN_ENDPOINT: &str = "https://auth.openai.com/oauth/token";
pub const REFRESH_SKEW: i64 = 300;

pub fn is_expired(access_token: &str, now: i64) -> bool {
    jwt::expiry(access_token).map_or(true, |exp| exp - now < REFRESH_SKEW)
}

/// 需要时续期并更新 `account` 里的 token。返回当前可用的 access_token。
pub async fn ensure_fresh(account: &mut CodexAccount) -> Result<String, QuotaError> {
    let current = account.access_token.clone().ok_or(QuotaError::MissingToken)?;
    if !is_expired(&current, crate::now_secs()) {
        return Ok(current);
    }
    let refresh = account
        .refresh_token
        .clone()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| QuotaError::TokenRefreshFailed("no refresh_token".into()))?;
    let resp = client()
        .post(TOKEN_ENDPOINT)
        .header("Accept", "application/json")
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh.as_str()),
            ("client_id", CLIENT_ID),
            ("scope", "openid profile email"),
        ])
        .send()
        .await
        .map_err(|e| QuotaError::TokenRefreshFailed(format!("transport: {e}")))?;
    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        return Err(QuotaError::TokenRefreshFailed(format!("http {}: {}", status.as_u16(), body)));
    }
    let root: Value = serde_json::from_str(&body).map_err(|_| QuotaError::TokenRefreshFailed("invalid json".into()))?;
    let access = root
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or_else(|| QuotaError::TokenRefreshFailed("no access_token in response".into()))?
        .to_string();
    let id = root.get("id_token").and_then(Value::as_str).map(str::to_string);
    let new_refresh = root.get("refresh_token").and_then(Value::as_str).map(str::to_string).unwrap_or(refresh);
    write_back(&account.path, &access, id.as_deref(), &new_refresh)?;
    account.access_token = Some(access.clone());
    account.refresh_token = Some(new_refresh);
    if id.is_some() {
        account.id_token = id;
    }
    Ok(access)
}

fn write_back(path: &Path, access: &str, id: Option<&str>, refresh: &str) -> Result<(), QuotaError> {
    let mut root: Map<String, Value> = std::fs::read(path)
        .ok()
        .and_then(|d| serde_json::from_slice(&d).ok())
        .unwrap_or_default();
    let mut tokens = root.get("tokens").and_then(Value::as_object).cloned().unwrap_or_default();
    tokens.insert("access_token".into(), access.into());
    if let Some(id) = id {
        tokens.insert("id_token".into(), id.into());
    }
    tokens.insert("refresh_token".into(), refresh.into());
    root.insert("tokens".into(), Value::Object(tokens));
    root.insert(
        "last_refresh".into(),
        chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true).into(),
    );
    let data = serde_json::to_vec_pretty(&root).map_err(|e| QuotaError::TokenRefreshFailed(e.to_string()))?;
    paths::write_atomic(path, &data).map_err(|e| QuotaError::TokenRefreshFailed(format!("write auth.json: {e}")))
}
