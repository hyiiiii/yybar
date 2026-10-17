import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter, MemoryRouter, Route, Routes } from "react-router";
import "./styles.css";
import { Layout } from "./Layout";
import { LobbyPage } from "./pages/Lobby";
import { TablePage } from "./pages/Table";
import { BoardPage } from "./pages/Board";
import { MePage } from "./pages/Me";
import { UserPage } from "./pages/User";
import { ConnectPage } from "./pages/Connect";

// 预览版跑在没有服务端路由的环境里，用内存路由
const Router = import.meta.env.VITE_DEMO ? MemoryRouter : BrowserRouter;

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Router>
      <Routes>
        <Route element={<Layout />}>
          <Route index element={<LobbyPage />} />
          <Route path="table/:id" element={<TablePage />} />
          <Route path="board" element={<BoardPage />} />
          <Route path="me" element={<MePage />} />
          <Route path="u/:login" element={<UserPage />} />
          <Route path="connect" element={<ConnectPage />} />
          <Route path="bar" element={<LobbyPage />} />
          <Route path="*" element={<p className="empty">这里没有桌子。</p>} />
        </Route>
      </Routes>
    </Router>
  </StrictMode>,
);
