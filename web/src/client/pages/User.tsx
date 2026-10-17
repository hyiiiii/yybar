import { useEffect, useState } from "react";
import { useParams } from "react-router";
import { api, fmtInt, fmtTokens, fmtUSD, type Profile } from "../api";
import { Avatar, DailyChart, ModelTable, Stat } from "../components";

export function ProfileView({ profile }: { profile: Profile }) {
  const { totals, points } = profile;
  const tokens = totals.input_tokens + totals.output_tokens + totals.cache_read_tokens + totals.cache_creation_tokens;
  return (
    <>
      <div className="stats">
        <Stat label="总花费" value={fmtUSD(totals.cost_micro)} hint={`${totals.active_days} 个活跃日`} />
        <Stat label="总 Token" value={fmtTokens(tokens)} hint={`输出 ${fmtTokens(totals.output_tokens)}`} />
        <Stat label="筹码" value={fmtInt(points.balance)} hint={`累计换得 ${fmtInt(points.earned)}`} />
      </div>
      <section className="card-box">
        <h2>近 30 天</h2>
        <DailyChart series={profile.series} />
      </section>
      <section className="card-box">
        <h2>花费最多的模型</h2>
        <ModelTable models={profile.models} />
      </section>
    </>
  );
}

export function UserPage() {
  const { login } = useParams();
  const [profile, setProfile] = useState<Profile | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    api<Profile>(`/api/users/${encodeURIComponent(login!)}`).then(setProfile, (e: Error) => setError(e.message));
  }, [login]);

  if (error) return <p className="error">{error}</p>;
  if (!profile) return <p className="empty">加载中…</p>;
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
