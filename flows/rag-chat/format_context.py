"""Format search results into a numbered context string and citations list."""

from typing import Any

from promptflow.core import tool


@tool
def format_context(search_results: list[dict[str, Any]]) -> dict[str, Any]:
    """Format search results into context for the LLM and a structured citations list.

    Args:
        search_results: List of dicts with keys: chunk, title, source_file.

    Returns:
        Dict with:
            context: Numbered context blocks as a single string.
            citations: List of dicts with keys: index, title, source_file.
    """
    if not search_results:
        return {"context": "No relevant documents found.", "citations": []}

    context_blocks: list[str] = []
    citations: list[dict[str, Any]] = []

    for i, result in enumerate(search_results, start=1):
        title = result.get("title", "Untitled")
        source_file = result.get("source_file", "Unknown")
        chunk = result.get("chunk", "")

        block = (
            f"[{i}] Title: {title}\n"
            f"Source: {source_file}\n"
            f"Content: {chunk}"
        )
        context_blocks.append(block)

        citations.append(
            {
                "index": i,
                "title": title,
                "source_file": source_file,
            }
        )

    context = "\n\n".join(context_blocks)
    return {"context": context, "citations": citations}
