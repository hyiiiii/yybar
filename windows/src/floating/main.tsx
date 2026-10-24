import React from "react";
import ReactDOM from "react-dom/client";
import "../shared/base.css";
import "./floating.css";
import { Floating } from "./Floating";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <Floating />
  </React.StrictMode>,
);
