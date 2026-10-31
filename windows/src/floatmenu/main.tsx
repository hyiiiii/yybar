import React from "react";
import ReactDOM from "react-dom/client";
import "../shared/base.css";
import "./floatmenu.css";
import { FloatingMenu } from "./FloatingMenu";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <FloatingMenu />
  </React.StrictMode>,
);
