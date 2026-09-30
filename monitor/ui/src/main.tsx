import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App.js";
import { EmbedStage } from "./embed/EmbedStage.js";
import { isEmbedUrl } from "./embed/params.js";
import "./styles.css";

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>{isEmbedUrl(window.location.search) ? <EmbedStage /> : <App />}</React.StrictMode>,
);
