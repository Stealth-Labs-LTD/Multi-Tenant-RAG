import type { Citation } from "../api/models";

interface CitationPanelProps {
  citations: Citation[];
  selectedIndex?: number;
}

export function CitationPanel({ citations, selectedIndex }: CitationPanelProps) {
  return (
    <div style={styles.panel}>
      <h3 style={styles.heading}>Sources</h3>
      <div style={styles.list}>
        {citations.map((citation) => (
          <div
            key={citation.index}
            style={{
              ...styles.card,
              ...(selectedIndex === citation.index ? styles.cardSelected : {}),
            }}
          >
            <div style={styles.cardHeader}>
              <span style={styles.badge}>{citation.index}</span>
              <span style={styles.cardTitle}>{citation.title}</span>
            </div>
            <div style={styles.sourceFile}>{citation.source_file}</div>
            <p style={styles.content}>{citation.content}</p>
          </div>
        ))}
      </div>
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  panel: {
    width: 320,
    borderLeft: "1px solid #e0e0e0",
    backgroundColor: "#fafafa",
    display: "flex",
    flexDirection: "column",
    flexShrink: 0,
    overflowY: "auto",
  },
  heading: {
    padding: "16px 16px 8px",
    margin: 0,
    fontSize: 14,
    fontWeight: 600,
    color: "#333",
  },
  list: {
    display: "flex",
    flexDirection: "column",
    gap: 8,
    padding: "0 16px 16px",
  },
  card: {
    padding: 12,
    borderRadius: 8,
    backgroundColor: "#fff",
    border: "1px solid #e0e0e0",
    transition: "border-color 0.15s",
  },
  cardSelected: {
    borderColor: "#0078D4",
    boxShadow: "0 0 0 1px #0078D4",
  },
  cardHeader: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    marginBottom: 4,
  },
  badge: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    background: "#0078D4",
    color: "#fff",
    borderRadius: "50%",
    width: 20,
    height: 20,
    fontSize: 11,
    fontWeight: 600,
    flexShrink: 0,
  },
  cardTitle: {
    fontSize: 13,
    fontWeight: 600,
    color: "#1a1a1a",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  sourceFile: {
    fontSize: 11,
    color: "#888",
    marginBottom: 6,
    paddingLeft: 28,
  },
  content: {
    fontSize: 12,
    color: "#555",
    margin: 0,
    lineHeight: 1.4,
    display: "-webkit-box",
    WebkitLineClamp: 4,
    WebkitBoxOrient: "vertical",
    overflow: "hidden",
  },
};
