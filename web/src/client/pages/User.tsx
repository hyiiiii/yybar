import { useEffect, useState } from "react";
import { useParams } from "react-router";
import { api, fmtInt, fmtTokens, fmtUSD, type Profile } from "../api";
import { Avatar, DailyChart, ModelTable, Stat } from "../components";
import { tr, useLang, useT } from "../i18n";

export function ProfileView({ profile }: { profile: Profile }) {
  const { totals, points } = profile;
  const t = useT();
  const tokens = totals.input_tokens + totals.output_tokens + totals.cache_read_tokens + totals.cache_creation_tokens;
  return (
    <>
      <div className="stats">
        <Stat label={t("总花费", "Total spend")} value={fmtUSD(totals.cost_micro)} hint={t(`${totals.active_days} 个活跃日`, `${totals.active_days} active days`)} />
        <Stat label={t("总 Token", "Total tokens")} value={fmtTokens(tokens)} hint={t(`输出 ${fmtTokens(totals.output_tokens)}`, `${fmtTokens(totals.output_tokens)} output`)} />
        <Stat label={t("筹码", "Chips")} value={fmtInt(points.balance)} hint={t(`累计换得 ${fmtInt(points.earned)}`, `${fmtInt(points.earned)} earned in total`)} />
      </div>
      <section className="card-box">
        <h2>{t("近 30 天", "Last 30 days")}</h2>
        <DailyChart series={profile.series} />
      </section>
      <section className="card-box">
        <h2>{t("花费最多的模型", "Top models by spend")}</h2>
        <ModelTable models={profile.models} />
      </section>
    </>
  );
}

export function UserPage() {
  const { login } = useParams();
  const [profile, setProfile] = useState<Profile | null>(null);
  const [error, setError] = useState<string | null>(null);
  const lang = useLang();
  const t = useT();
  useEffect(() => {
    api<Profile>(`/api/users/${encodeURIComponent(login!)}`).then(setProfile, (e: Error) => setError(e.message));
  }, [login]);

  if (error) return <p className="error">{error === "没有这个用户，或对方未公开" ? t(error, "No such user, or their profile is private") : tr(error, lang)}</p>;
  if (!profile) return <p className="empty">{t("加载中…", "Loading…")}</p>;
  return (
    <>
      <div className="profile-head">
        <Avatar url={profile.user.avatarUrl} login={profile.user.login} size={56} />
        <div>
          <h1>{profile.user.name || profile.user.login}</h1>
          <a href={`https://github.com/${profile.user.login}`} target="_blank" rel="noreferrer">@{profile.user.login}</a>
        </div>
      </div>
      <ProfileView profile={profile} />
    </>
  );
}
