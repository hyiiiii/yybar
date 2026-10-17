import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter, Route, Routes } from "react-router";
import "./styles.css";
import { Layout } from "./Layout";
import { HomePage } from "./pages/Home";
import { MePage } from "./pages/Me";
import { UserPage } from "./pages/User";
import { ConnectPage } from "./pages/Connect";
import { BarPage } from "./pages/Bar";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <BrowserRouter>
      <Routes>
        <Route element={<Layout />}>
          <Route index element={<HomePage />} />
          <Route path="me" element={<MePage />} />
          <Route path="u/:login" element={<UserPage />} />
          <Route path="connect" element={<ConnectPage />} />
          <Route path="bar" element={<BarPage />} />
          <Route path="*" element={<p className="empty">页面不存在。</p>} />
        </Route>
      </Routes>
    </BrowserRouter>
  </StrictMode>,
);
