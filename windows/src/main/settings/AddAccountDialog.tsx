// 设置 · 服务 →「添加账号…」（对应 Mac `AddAccountSheet`）。三步：
// 1. 选服务商（Codex / Claude Code / Grok / Gemini · Antigravity）
//    - Gemini · Antigravity 没有「方式」一步：在控制台窗口里用 agy 在独立目录登录，回来点「完成添加」。
// 2. 选方式：在浏览器中登录（调用官方 CLI，独立目录，不影响本机已登录的账号）/ 粘贴凭据
// 3. 浏览器登录进度（Claude 要把浏览器页面上的授权码粘贴回来），或粘贴表单
// 步骤切换时内容按前进 / 后退方向滑入并淡入。关掉窗口时没添加成功的登录会被取消、目录删掉。

import { useEffect, useRef, useState } from "react";
import { api, inTauri, useEvent } from "../../shared/api";
import { Icon, ServiceTile } from "../../shared/design";
import { tr } from "../../shared/l10n";
import type { LoginResult, LoginView, Provider, StateSnapshot, UsageApp } from "../../shared/types";

type Step = "provider" | "method" | "browser" | "paste" | "terminal";
const ORDER: Record<Step, number> = { provider: 0, method: 1, browser: 2, paste: 2, terminal: 2 };

const PROVIDERS: { id: Provider; app: UsageApp; title: string; vendor: string }[] = [
  { id: "codex", app: "codex", title: "Codex", vendor: "OpenAI" },
  { id: "claude", app: "claude", title: "Claude Code", vendor: "Anthropic" },
  { id: "grok", app: "grok", title: "Grok", vendor: "xAI" },
  { id: "google", app: "agy", title: "Gemini · Antigravity", vendor: "Google" },
];

const LOGIN_COMMAND: Record<Provider, string> = { codex: "codex login", claude: "claude auth login", grok: "grok login --oauth", google: "agy" };
const CREDENTIALS_FILE: Record<Provider, string> = {
  codex: "%USERPROFILE%\\.codex\\auth.json",
  claude: "%USERPROFILE%\\.claude\\.credentials.json",
  grok: "%USERPROFILE%\\.grok\\auth.json",
  google: "",
};

/** 登录链接加 prompt=login：要求服务商重新显示登录表单，而不是沿用浏览器里已登录的账号。 */
function switchAccountUrl(url: string): string {
  try {
    const u = new URL(url);
    u.searchParams.set("prompt", "login");
    return u.toString();
  } catch {
    return url;
  }
}

export function AddAccountDialog({ state, onClose }: { state: StateSnapshot; onClose: () => void }) {
  const [step, setStep] = useState<Step>("provider");
  const [forward, setForward] = useState(true);
  const [provider, setProvider] = useState<Provider>("codex");
  const [method, setMethod] = useState<"browser" | "paste">("browser");
  const [added, setAdded] = useState<string | null>(null);

  // 浏览器登录
  const [login, setLogin] = useState<LoginView | null>(null);
  const [startError, setStartError] = useState<string | null>(null);
  const [importError, setImportError] = useState<string | null>(null);
  const [code, setCode] = useState("");
  const loginRef = useRef<string | null>(null);

  // 粘贴
  const [pasteText, setPasteText] = useState("");
  const [busy, setBusy] = useState(false);
  const [pasteError, setPasteError] = useState<string | null>(null);

  // Google（控制台里用 agy 登录）
  const [agyFolder, setAgyFolder] = useState<string | null>(null);
  const [terminalError, setTerminalError] = useState<string | null>(null);
  const folderRef = useRef<string | null>(null);
  const addedRef = useRef(false);

  const cliInstalled = (p: Provider) => (p === "google" ? state.clis.agy : state.clis[p]);

  const go = (next: Step) => {
    setForward(ORDER[next] >= ORDER[step]);
    setStep(next);
  };

  useEvent<LoginView>("login", (view) => {
    if (view.id === loginRef.current) setLogin(view);
  });
  useEvent<LoginResult>("login-result", (r) => {
    if (r.id !== loginRef.current) return;
    if (r.ok) {
      addedRef.current = true;
      setAdded(r.name ?? "");
    } else {
      setImportError(r.error ?? "");
    }
  });

  // 关窗：没添加成功的登录取消、目录删掉
  useEffect(
    () => () => {
      if (addedRef.current) return;
      if (loginRef.current) api.loginCancel(loginRef.current);
      if (folderRef.current) api.googleLoginCancel(folderRef.current);
    },
    [],
  );

  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [onClose]);

  const startBrowser = async () => {
    setLogin(null);
    setStartError(null);
    setImportError(null);
    setCode("");
    if (loginRef.current) api.loginCancel(loginRef.current);
    loginRef.current = null;
    go("browser");
    if (!inTauri) return;
    try {
      const view = await api.loginStart(provider);
      if (view) {
        loginRef.current = view.id;
        setLogin(view);
      }
    } catch (e) {
      setStartError(String(e));
    }
  };

  const startTerminal = async () => {
    setTerminalError(null);
    go("terminal");
    if (!inTauri || folderRef.current) return;
    try {
      const folder = await api.googleLoginStart();
      if (folder) {
        folderRef.current = folder;
        setAgyFolder(folder);
      }
    } catch (e) {
      setTerminalError(String(e));
    }
  };

  const finishGoogle = async () => {
    if (!agyFolder) return;
    setBusy(true);
    setTerminalError(null);
    try {
      const name = await api.googleLoginFinish(agyFolder);
      addedRef.current = true;
      setAdded(name ?? "");
    } catch (e) {
      setTerminalError(String(e));
    } finally {
      setBusy(false);
    }
  };

  const savePaste = async () => {
    setBusy(true);
    setPasteError(null);
    try {
      const name = await api.addAccountPaste(provider, pasteText);
      addedRef.current = true;
      setAdded(name ?? "");
    } catch (e) {
      setPasteError(String(e));
    } finally {
      setBusy(false);
    }
  };

  const back = () => {
    if (step === "browser" && loginRef.current) {
      api.loginCancel(loginRef.current);
      loginRef.current = null;
      setLogin(null);
    }
    go(step === "method" || step === "terminal" ? "provider" : "method");
  };

  const info = PROVIDERS.find((p) => p.id === provider)!;
  const canContinue = step === "provider" || (step === "method" && (method === "paste" || cliInstalled(provider)));

  return (
    <div className="dialog-backdrop" onMouseDown={onClose}>
      <div className="add-account" onMouseDown={(e) => e.stopPropagation()}>
        <header className="aa-header">
          <span className="aa-title">{tr("Add Account", "添加账号")}</span>
          <span style={{ flex: 1 }} />
          <span className={`aa-step ${step === "provider" ? "active" : ""}`}>{tr("Service", "服务商")}</span>
          <Icon name="chevronRight" size={9} className="tertiary" />
          <span className={`aa-step ${step === "method" ? "active" : ""}`}>{tr("Method", "方式")}</span>
          <Icon name="chevronRight" size={9} className="tertiary" />
          <span className={`aa-step ${ORDER[step] === 2 ? "active" : ""}`}>{tr("Sign in", "登录")}</span>
        </header>
        <div className="divider" />
        <div className="aa-body">
          <div key={step} className={`aa-content ${forward ? "from-right" : "from-left"}`}>
            {added != null ? (
              <Done name={added} provider={info.title} />
            ) : step === "provider" ? (
              <>
                <p className="aa-question">{tr("Which service is this account for?", "要添加哪个服务的账号？")}</p>
                <div className="aa-choices">
                  {PROVIDERS.map((p) => (
                    <button key={p.id} className={`aa-choice ${provider === p.id ? "selected" : ""}`} onClick={() => setProvider(p.id)}>
                      <ServiceTile app={p.app} size={26} logoSize={15} radius={7} />
                      <span className="aa-choice-text">
                        <b>{p.title}</b>
                        <span className="secondary">{p.vendor}</span>
                      </span>
                      <span style={{ flex: 1 }} />
                      <span className={`aa-radio ${provider === p.id ? "on" : ""}`} />
                    </button>
                  ))}
                </div>
                {provider === "google" && (
                  <p className="aa-note">
                    {tr(
                      "One Google account covers both Gemini and Antigravity quotas. You'll sign in with agy in a console window, in a separate folder; agy's sign-in on this PC isn't touched.",
                      "一个 Google 账号同时对应 Gemini 和 Antigravity 两份额度。会在控制台窗口里用 agy 在独立目录登录，不影响本机 agy 的登录。",
                    )}
                  </p>
                )}
              </>
            ) : step === "method" ? (
              <>
                <p className="aa-question">{tr(`How do you want to add the ${info.title} account?`, `怎样添加 ${info.title} 账号？`)}</p>
                <div className="aa-choices">
                  <button className={`aa-choice tall ${method === "browser" ? "selected" : ""}`} onClick={() => setMethod("browser")}>
                    <Icon name="globe" size={16} />
                    <span className="aa-choice-text">
                      <span>
                        <b>{tr("Sign in in the browser", "在浏览器中登录")}</b>
                        <span className="aa-badge">{tr("Recommended", "推荐")}</span>
                      </span>
                      <span className="secondary">
                        {cliInstalled(provider)
                          ? tr(
                              `Runs the official ${LOGIN_COMMAND[provider]} in a separate folder. Your current sign-in on this PC isn't touched.`,
                              `在独立目录里运行官方的 ${LOGIN_COMMAND[provider]}，不影响本机已登录的账号。`,
                            )
                          : tr(
                              `Needs the ${LOGIN_COMMAND[provider].split(" ")[0]} command, which isn't installed on this PC. Paste credentials instead.`,
                              `需要 ${LOGIN_COMMAND[provider].split(" ")[0]} 命令，本机没有安装，请改用粘贴凭据。`,
                            )}
                      </span>
                    </span>
                    <span style={{ flex: 1 }} />
                    <span className={`aa-radio ${method === "browser" ? "on" : ""}`} />
                  </button>
                  <button className={`aa-choice tall ${method === "paste" ? "selected" : ""}`} onClick={() => setMethod("paste")}>
                    <Icon name="clipboard" size={16} />
                    <span className="aa-choice-text">
                      <b>{tr("Paste credentials", "粘贴凭据")}</b>
                      <span className="secondary">
                        {tr(`Paste ${CREDENTIALS_FILE[provider]} from another computer.`, `粘贴另一台电脑上的 ${CREDENTIALS_FILE[provider]}。`)}
                      </span>
                    </span>
                    <span style={{ flex: 1 }} />
                    <span className={`aa-radio ${method === "paste" ? "on" : ""}`} />
                  </button>
                </div>
              </>
            ) : step === "browser" ? (
              <BrowserStep
                login={login}
                startError={startError}
                importError={importError}
                code={code}
                onCode={setCode}
                onSubmitCode={() => login && api.loginSubmitCode(login.id, code)}
                onRetry={startBrowser}
              />
            ) : step === "paste" ? (
              <>
                <p className="aa-question">
                  {tr(`Paste the contents of ${CREDENTIALS_FILE[provider]}:`, `粘贴 ${CREDENTIALS_FILE[provider]} 的内容：`)}
                </p>
                <textarea
                  className="aa-paste num"
                  value={pasteText}
                  onChange={(e) => setPasteText(e.target.value)}
                  placeholder={provider === "codex" ? '{ "tokens": { "access_token": "…", "refresh_token": "…" } }' : "{ … }"}
                  spellCheck={false}
                  autoFocus
                />
                <p className="aa-note">
                  {provider === "codex"
                    ? tr("You can paste several accounts at once as a JSON array.", "可以用 JSON 数组一次粘贴几个账号。")
                    : tr("Saved only on this PC, readable by your Windows user.", "只保存在本机，只有当前 Windows 用户能读。")}
                </p>
                {pasteError && <p className="aa-error">{pasteError}</p>}
              </>
            ) : (
              <>
                <div className="aa-progress-title">
                  <Icon name="terminal" size={15} />
                  <b>{tr("Sign in with agy in a console window", "在控制台窗口里用 agy 登录")}</b>
                </div>
                <ol className="aa-steps">
                  <li>{tr("A console window opened running agy in a separate folder.", "已打开一个控制台窗口，在独立目录里运行 agy。")}</li>
                  <li>
                    {tr(
                      "Open the sign-in link it shows, sign in with the Google account to add, and paste the code back into the console.",
                      "打开它给出的登录链接，用要添加的 Google 账号登录，把授权码粘贴回控制台。",
                    )}
                  </li>
                  <li>{tr("When agy says you're signed in, type /exit, then click “Finish adding” here.", "agy 提示登录成功后输入 /exit，再回到这里点「完成添加」。")}</li>
                </ol>
                {agyFolder && (
                  <button className="link-button" onClick={() => api.googleLoginReopen(agyFolder)}>
                    <Icon name="terminal" size={12} />
                    {tr("Open the console again", "重新打开控制台")}
                  </button>
                )}
                {busy && <Progress text={tr("Checking the account (about 15 s)…", "正在检查账号（约 15 秒）…")} />}
                {terminalError && <p className="aa-error">{terminalError}</p>}
              </>
            )}
          </div>
        </div>
        <div className="divider" />
        <footer className="aa-footer">
          {added == null && step !== "provider" && (
            <button className="button" onClick={back}>
              {tr("Back", "返回")}
            </button>
          )}
          <span style={{ flex: 1 }} />
          {added != null ? (
            <button className="button primary" onClick={onClose}>
              {tr("Done", "完成")}
            </button>
          ) : (
            <>
              <button className="button" onClick={onClose}>
                {tr("Cancel", "取消")}
              </button>
              {step === "provider" && (
                <button className="button primary" onClick={() => (provider === "google" ? startTerminal() : go("method"))} disabled={!canContinue}>
                  {tr("Continue", "继续")}
                </button>
              )}
              {step === "method" && (
                <button className="button primary" disabled={!canContinue} onClick={() => (method === "browser" ? startBrowser() : go("paste"))}>
                  {tr("Continue", "继续")}
                </button>
              )}
              {step === "paste" && (
                <button className="button primary" disabled={busy || !pasteText.trim()} onClick={savePaste}>
                  {busy ? tr("Adding…", "正在添加…") : tr("Add", "添加")}
                </button>
              )}
              {step === "terminal" && (
                <button className="button primary" disabled={busy || !agyFolder} onClick={finishGoogle}>
                  {tr("Finish adding", "完成添加")}
                </button>
              )}
            </>
          )}
        </footer>
      </div>
    </div>
  );
}

function BrowserStep({ login, startError, importError, code, onCode, onSubmitCode, onRetry }: {
  login: LoginView | null;
  startError: string | null;
  importError: string | null;
  code: string;
  onCode: (v: string) => void;
  onSubmitCode: () => void;
  onRetry: () => void;
}) {
  if (startError) return <ErrorBlock title={tr("Couldn't start sign-in.", "无法启动登录。")} detail={startError} onRetry={onRetry} />;
  if (importError) return <ErrorBlock title={tr("Signed in, but the account couldn't be added.", "已登录，但没能添加这个账号。")} detail={importError} onRetry={onRetry} />;
  const phase = login?.phase.kind ?? "starting";
  if (login?.phase.kind === "exited" && !login.phase.succeeded) {
    return <ErrorBlock title={tr("Sign-in didn't finish.", "登录没有完成。")} detail={login.outputTail} onRetry={onRetry} />;
  }
  if (login?.phase.kind === "failed") return <ErrorBlock title={tr("Sign-in didn't finish.", "登录没有完成。")} detail={login.phase.message} onRetry={onRetry} />;
  return (
    <>
      {phase === "starting" && <Progress text={tr("Starting sign-in…", "正在启动登录…")} />}
      {phase === "waitingForBrowser" && <Progress text={tr("Finish signing in in your browser. This window continues on its own.", "请在浏览器中完成登录，这个窗口会自动继续。")} />}
      {phase === "exited" && <Progress text={tr("Signed in. Adding the account…", "已登录，正在添加账号…")} />}
      {phase === "needsCode" && (
        <div className="aa-code">
          <p>{tr("After approving in the browser, Claude shows an authorization code. Paste it here:", "在浏览器里授权后，Claude 会显示一个授权码，粘贴到这里：")}</p>
          <span className="row-inline">
            <input
              className="text-input num"
              value={code}
              onChange={(e) => onCode(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && code.trim() && onSubmitCode()}
              placeholder={tr("Authorization code", "授权码")}
              autoFocus
            />
            <button className="button primary" disabled={!code.trim()} onClick={onSubmitCode}>
              {tr("Submit", "提交")}
            </button>
          </span>
        </div>
      )}
      {login?.loginUrl && phase !== "exited" && (
        <div className="aa-links">
          <button className="link-button" onClick={() => api.openUrl(login.loginUrl!)}>
            <Icon name="external" size={12} />
            {tr("Open sign-in page again", "重新打开登录页")}
          </button>
          <button className="link-button" onClick={() => api.openUrl(switchAccountUrl(login.loginUrl!))}>
            <Icon name="personPlus" size={12} />
            {tr("Sign in with another account", "用其他账号登录")}
          </button>
          <p className="aa-note">
            {tr(
              "If the page shows the account already signed in on this PC, use “Sign in with another account”, or sign out on that page first.",
              "如果页面直接用了本机已登录的账号，点「用其他账号登录」，或先在页面上退出登录。",
            )}
          </p>
        </div>
      )}
    </>
  );
}

function Progress({ text }: { text: string }) {
  return (
    <div className="aa-progress">
      <span className="spinner" />
      <span>{text}</span>
    </div>
  );
}

function ErrorBlock({ title, detail, onRetry }: { title: string; detail: string; onRetry: () => void }) {
  return (
    <div className="aa-error-block">
      <div className="aa-progress-title">
        <Icon name="warning" size={14} />
        <b>{title}</b>
      </div>
      {detail.trim() && <pre className="aa-tail num">{detail.trim().split("\n").slice(-8).join("\n")}</pre>}
      <button className="button" onClick={onRetry}>
        <Icon name="refresh" size={12} />
        {tr("Try again", "重试")}
      </button>
    </div>
  );
}

function Done({ name, provider }: { name: string; provider: string }) {
  return (
    <div className="aa-done">
      <span className="aa-done-check">
        <Icon name="check" size={22} />
      </span>
      <b>{tr("Account added", "已添加账号")}</b>
      <span className="secondary">
        {name ? `${provider} · ${name}` : provider}
      </span>
      <span className="aa-note">
        {tr("Choose whether it shows in the taskbar and floating window on the Services page.", "可以在「服务」页勾选它是否显示在任务栏和悬浮窗。")}
      </span>
    </div>
  );
}
