import React from "react";
import ReactDOM from "react-dom/client";
import "../shared/base.css";
import "./popover.css";
import { Popover } from "./Popover";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <Popover />
  </React.StrictMode>,
);
