import type { ReactNode } from "react";

/** 统计页里的卡片：标题行（左标题 + 标题旁小装饰，右侧控件）+ 内容。 */
export function Panel({ title, accessory, right, children, className }: { title: ReactNode; accessory?: ReactNode; right?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <div className={`panel stats-panel ${className ?? ""}`}>
      <div className="panel-head">
        <div className="panel-title">
          {title}
          {accessory}
        </div>
        <span style={{ flex: 1 }} />
        {right}
      </div>
      {children}
    </div>
  );
}

export function Placeholder({ height, message }: { height: number; message: string }) {
  return (
    <div className="placeholder" style={{ height }}>
      {message}
    </div>
  );
}
