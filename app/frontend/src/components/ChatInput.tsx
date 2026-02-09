import { useState } from "react";

interface ChatInputProps {
  onSend: (message: string) => void;
  disabled: boolean;
}

export function ChatInput({ onSend, disabled }: ChatInputProps) {
  const [input, setInput] = useState("");

  const handleSubmit = () => {
    const trimmed = input.trim();
    if (!trimmed || disabled) return;
    onSend(trimmed);
    setInput("");
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSubmit();
    }
  };

  return (
    <div style={styles.container}>
      <div style={styles.inputWrapper}>
        <input
          type="text"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder="Type a message..."
          disabled={disabled}
          style={styles.input}
        />
        <button
          onClick={handleSubmit}
          disabled={disabled || !input.trim()}
          style={{
            ...styles.button,
            opacity: disabled || !input.trim() ? 0.5 : 1,
          }}
        >
          Send
        </button>
      </div>
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: {
    padding: "16px 24px",
    borderTop: "1px solid #e0e0e0",
    backgroundColor: "#fff",
    flexShrink: 0,
  },
  inputWrapper: {
    display: "flex",
    gap: 8,
    maxWidth: 800,
    margin: "0 auto",
  },
  input: {
    flex: 1,
    padding: "10px 16px",
    borderRadius: 24,
    border: "1px solid #d0d0d0",
    fontSize: 14,
    outline: "none",
    fontFamily: "inherit",
  },
  button: {
    padding: "10px 20px",
    borderRadius: 24,
    border: "none",
    backgroundColor: "#0078D4",
    color: "#fff",
    fontSize: 14,
    fontWeight: 600,
    cursor: "pointer",
    fontFamily: "inherit",
  },
};
