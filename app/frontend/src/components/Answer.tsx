import ReactMarkdown from "react-markdown";
import type { Citation } from "../api/models";

interface AnswerProps {
  content: string;
  citations: Citation[];
  onCitationClick?: (index: number) => void;
}

export function Answer({ content, citations, onCitationClick }: AnswerProps) {
  const processedContent = content.replace(
    /\[doc(\d+)\]/g,
    (_match, num: string) => {
      const index = parseInt(num, 10);
      const citation = citations.find((c) => c.index === index);
      if (citation) {
        return `[${index}]`;
      }
      return `[${index}]`;
    }
  );

  return (
    <div style={styles.answer}>
      <ReactMarkdown
        components={{
          p: ({ children }) => {
            return <p style={styles.paragraph}>{processContent(children, citations, onCitationClick)}</p>;
          },
        }}
      >
        {processedContent}
      </ReactMarkdown>
    </div>
  );
}

function processContent(
  children: React.ReactNode,
  citations: Citation[],
  onCitationClick?: (index: number) => void
): React.ReactNode {
  if (!Array.isArray(children)) {
    if (typeof children === "string") {
      return replaceCitationRefs(children, citations, onCitationClick);
    }
    return children;
  }

  return children.map((child, i) => {
    if (typeof child === "string") {
      return <span key={i}>{replaceCitationRefs(child, citations, onCitationClick)}</span>;
    }
    return child;
  });
}

function replaceCitationRefs(
  text: string,
  citations: Citation[],
  onCitationClick?: (index: number) => void
): React.ReactNode[] {
  const parts: React.ReactNode[] = [];
  const regex = /\[(\d+)\]/g;
  let lastIndex = 0;
  let match: RegExpExecArray | null;

  while ((match = regex.exec(text)) !== null) {
    if (match.index > lastIndex) {
      parts.push(text.slice(lastIndex, match.index));
    }

    const index = parseInt(match[1], 10);
    const citation = citations.find((c) => c.index === index);

    if (citation) {
      parts.push(
        <button
          key={`cite-${match.index}`}
          onClick={() => onCitationClick?.(index)}
          style={styles.citationRef}
          title={citation.title}
        >
          {index}
        </button>
      );
    } else {
      parts.push(match[0]);
    }

    lastIndex = regex.lastIndex;
  }

  if (lastIndex < text.length) {
    parts.push(text.slice(lastIndex));
  }

  return parts;
}

const styles: Record<string, React.CSSProperties> = {
  answer: {
    lineHeight: 1.6,
  },
  paragraph: {
    margin: "4px 0",
  },
  citationRef: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    background: "#0078D4",
    color: "#fff",
    border: "none",
    borderRadius: "50%",
    width: 20,
    height: 20,
    fontSize: 11,
    fontWeight: 600,
    cursor: "pointer",
    verticalAlign: "super",
    marginLeft: 2,
    marginRight: 2,
    lineHeight: 1,
    padding: 0,
  },
};
