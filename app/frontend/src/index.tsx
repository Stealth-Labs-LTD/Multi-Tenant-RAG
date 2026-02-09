import React from "react";
import ReactDOM from "react-dom/client";
import "./index.css";
import { Chat } from "./pages/chat/Chat";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <Chat />
  </React.StrictMode>
);
