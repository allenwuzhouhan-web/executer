#!/usr/bin/env python3
"""
Executer RAG Engine
Local Retrieval-Augmented Generation with ChromaDB vector store.

Supports: ingest documents, semantic search, list/delete collections.

Usage:
    python3 rag_engine.py ingest --path /path/to/file_or_dir --collection my_docs
    python3 rag_engine.py search --query "how does auth work" --collection my_docs --limit 5
    python3 rag_engine.py list
    python3 rag_engine.py delete --collection my_docs
    python3 rag_engine.py info --collection my_docs
"""

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

try:
    import chromadb
    from chromadb.config import Settings as ChromaSettings
except ImportError:
    print(json.dumps({"success": False, "error": "chromadb not installed. Run: pip3 install chromadb"}))
    sys.exit(1)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

STORE_DIR = os.path.join(
    os.path.expanduser("~/Library/Application Support/Executer"), "rag_store"
)

# Supported file extensions and their loaders
SUPPORTED_EXTENSIONS = {
    ".txt", ".md", ".markdown", ".rst", ".py", ".swift", ".js", ".ts",
    ".json", ".yaml", ".yml", ".xml", ".html", ".htm", ".css",
    ".csv", ".tsv", ".log", ".sh", ".bash", ".zsh",
    ".c", ".cpp", ".h", ".hpp", ".java", ".go", ".rs", ".rb",
    ".pdf", ".docx",
}

# Chunk settings
CHUNK_SIZE = 800       # characters per chunk
CHUNK_OVERLAP = 100    # overlap between chunks

# ---------------------------------------------------------------------------
# Text extraction
# ---------------------------------------------------------------------------

def extract_text(file_path: str) -> str | None:
    """Extract text content from a file. Returns None if unsupported/unreadable."""
    ext = Path(file_path).suffix.lower()

    if ext == ".pdf":
        return _extract_pdf(file_path)
    elif ext == ".docx":
        return _extract_docx(file_path)
    elif ext == ".csv" or ext == ".tsv":
        return _extract_csv(file_path, ext)
    else:
        # Plain text / code files
        try:
            with open(file_path, "r", encoding="utf-8", errors="replace") as f:
                return f.read()
        except Exception:
            return None


def _extract_pdf(path: str) -> str | None:
    try:
        import PyPDF2
        text_parts = []
        with open(path, "rb") as f:
            reader = PyPDF2.PdfReader(f)
            for page in reader.pages:
                t = page.extract_text()
                if t:
                    text_parts.append(t)
        return "\n\n".join(text_parts) if text_parts else None
    except Exception as e:
        return None


def _extract_docx(path: str) -> str | None:
    try:
        import docx
        doc = docx.Document(path)
        return "\n\n".join(p.text for p in doc.paragraphs if p.text.strip())
    except Exception:
        return None


def _extract_csv(path: str, ext: str) -> str | None:
    import csv
    try:
        delimiter = "\t" if ext == ".tsv" else ","
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            reader = csv.reader(f, delimiter=delimiter)
            rows = []
            for i, row in enumerate(reader):
                rows.append(" | ".join(row))
                if i > 5000:  # cap at 5k rows
                    break
        return "\n".join(rows) if rows else None
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Text splitting
# ---------------------------------------------------------------------------

def split_text(text: str, chunk_size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP) -> list[str]:
    """Split text into overlapping chunks at sentence/paragraph boundaries."""
    if not text or not text.strip():
        return []

    # Split on double newlines (paragraphs) first, then sentences
    paragraphs = re.split(r"\n\s*\n", text)
    chunks = []
    current = ""

    for para in paragraphs:
        para = para.strip()
        if not para:
            continue

        if len(current) + len(para) + 2 <= chunk_size:
            current = (current + "\n\n" + para).strip()
        else:
            if current:
                chunks.append(current)
            # If paragraph itself exceeds chunk_size, split by sentences
            if len(para) > chunk_size:
                sentences = re.split(r"(?<=[.!?])\s+", para)
                current = ""
                for sent in sentences:
                    if len(current) + len(sent) + 1 <= chunk_size:
                        current = (current + " " + sent).strip()
                    else:
                        if current:
                            chunks.append(current)
                        # Very long sentence — hard split
                        if len(sent) > chunk_size:
                            for i in range(0, len(sent), chunk_size - overlap):
                                chunks.append(sent[i : i + chunk_size])
                            current = ""
                        else:
                            current = sent
            else:
                current = para

    if current:
        chunks.append(current)

    # Add overlap: prepend tail of previous chunk to each subsequent chunk
    if overlap > 0 and len(chunks) > 1:
        overlapped = [chunks[0]]
        for i in range(1, len(chunks)):
            prev_tail = chunks[i - 1][-overlap:]
            overlapped.append(prev_tail + " " + chunks[i])
        chunks = overlapped

    return [c for c in chunks if c.strip()]


# ---------------------------------------------------------------------------
# ChromaDB client
# ---------------------------------------------------------------------------

def get_client() -> chromadb.ClientAPI:
    """Get persistent ChromaDB client."""
    os.makedirs(STORE_DIR, exist_ok=True)
    return chromadb.PersistentClient(
        path=STORE_DIR,
        settings=ChromaSettings(anonymized_telemetry=False),
    )


def file_hash(path: str) -> str:
    """Quick hash of file path + mtime + size for dedup."""
    stat = os.stat(path)
    key = f"{os.path.abspath(path)}:{stat.st_mtime}:{stat.st_size}"
    return hashlib.md5(key.encode()).hexdigest()


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_ingest(args) -> dict:
    """Ingest files into a ChromaDB collection."""
    target = os.path.expanduser(args.path)
    collection_name = args.collection or "default"

    if not os.path.exists(target):
        return {"success": False, "error": f"Path not found: {target}"}

    # Gather files
    files = []
    if os.path.isfile(target):
        files = [target]
    else:
        for root, _, filenames in os.walk(target):
            for fn in filenames:
                fp = os.path.join(root, fn)
                if Path(fp).suffix.lower() in SUPPORTED_EXTENSIONS:
                    files.append(fp)
            if len(files) > 2000:
                break

    if not files:
        return {"success": False, "error": f"No supported files found in {target}"}

    client = get_client()
    collection = client.get_or_create_collection(
        name=collection_name,
        metadata={"hnsw:space": "cosine"},
    )

    # Check which files are already ingested (by hash)
    ingested = 0
    skipped = 0
    errors = []
    total_chunks = 0

    for fp in files:
        fh = file_hash(fp)

        # Check if already ingested with same hash
        existing = collection.get(where={"file_hash": fh}, limit=1)
        if existing and existing["ids"]:
            skipped += 1
            continue

        text = extract_text(fp)
        if not text or len(text.strip()) < 10:
            skipped += 1
            continue

        chunks = split_text(text)
        if not chunks:
            skipped += 1
            continue

        # Remove old versions of same file path
        old = collection.get(where={"source": os.path.abspath(fp)}, limit=10000)
        if old and old["ids"]:
            collection.delete(ids=old["ids"])

        # Add chunks
        ids = [f"{fh}_{i}" for i in range(len(chunks))]
        metadatas = [
            {
                "source": os.path.abspath(fp),
                "file_hash": fh,
                "chunk_index": i,
                "filename": os.path.basename(fp),
            }
            for i in range(len(chunks))
        ]

        try:
            # Batch in groups of 100
            for batch_start in range(0, len(chunks), 100):
                batch_end = min(batch_start + 100, len(chunks))
                collection.add(
                    ids=ids[batch_start:batch_end],
                    documents=chunks[batch_start:batch_end],
                    metadatas=metadatas[batch_start:batch_end],
                )
            ingested += 1
            total_chunks += len(chunks)
        except Exception as e:
            errors.append(f"{os.path.basename(fp)}: {e}")

    result = {
        "success": True,
        "collection": collection_name,
        "files_ingested": ingested,
        "files_skipped": skipped,
        "total_chunks": total_chunks,
        "collection_total": collection.count(),
    }
    if errors:
        result["errors"] = errors[:10]
    return result


def cmd_search(args) -> dict:
    """Semantic search across a collection."""
    query = args.query
    collection_name = args.collection or "default"
    limit = args.limit or 5

    if not query:
        return {"success": False, "error": "Query is required"}

    client = get_client()
    try:
        collection = client.get_collection(name=collection_name)
    except Exception:
        return {"success": False, "error": f"Collection '{collection_name}' not found"}

    results = collection.query(
        query_texts=[query],
        n_results=min(limit, 20),
        include=["documents", "metadatas", "distances"],
    )

    matches = []
    if results and results["documents"] and results["documents"][0]:
        for i, doc in enumerate(results["documents"][0]):
            try:
                meta = results["metadatas"][0][i] if results["metadatas"] else {}
            except (IndexError, KeyError):
                meta = {}
            try:
                dist = results["distances"][0][i] if results["distances"] else None
            except (IndexError, KeyError):
                dist = None
            matches.append({
                "content": doc,
                "source": meta.get("source", "unknown"),
                "filename": meta.get("filename", "unknown"),
                "chunk_index": meta.get("chunk_index", 0),
                "relevance": round(1.0 - (dist or 0), 4),  # cosine: lower distance = more relevant
            })

    return {
        "success": True,
        "collection": collection_name,
        "query": query,
        "results": matches,
        "total_results": len(matches),
    }


def cmd_list(args) -> dict:
    """List all collections with stats."""
    client = get_client()
    collections = client.list_collections()

    items = []
    for col in collections:
        c = client.get_collection(name=col.name)
        # Get unique source files
        all_meta = c.get(include=["metadatas"], limit=10000)
        sources = set()
        if all_meta and all_meta["metadatas"]:
            for m in all_meta["metadatas"]:
                if m and "source" in m:
                    sources.add(m["source"])

        items.append({
            "name": col.name,
            "chunks": c.count(),
            "files": len(sources),
        })

    return {
        "success": True,
        "collections": items,
        "total": len(items),
        "store_path": STORE_DIR,
    }


def cmd_delete(args) -> dict:
    """Delete a collection."""
    collection_name = args.collection
    if not collection_name:
        return {"success": False, "error": "Collection name is required"}

    client = get_client()
    try:
        client.delete_collection(name=collection_name)
        return {"success": True, "deleted": collection_name}
    except Exception as e:
        return {"success": False, "error": f"Failed to delete '{collection_name}': {e}"}


def cmd_info(args) -> dict:
    """Get detailed info about a collection."""
    collection_name = args.collection or "default"

    client = get_client()
    try:
        collection = client.get_collection(name=collection_name)
    except Exception:
        return {"success": False, "error": f"Collection '{collection_name}' not found"}

    all_meta = collection.get(include=["metadatas"], limit=10000)
    sources = {}
    if all_meta and all_meta["metadatas"]:
        for m in all_meta["metadatas"]:
            if m and "source" in m:
                src = m["source"]
                sources[src] = sources.get(src, 0) + 1

    file_list = [{"path": k, "chunks": v} for k, v in sorted(sources.items())]

    return {
        "success": True,
        "collection": collection_name,
        "total_chunks": collection.count(),
        "total_files": len(sources),
        "files": file_list[:100],  # cap output
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Executer RAG Engine")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # ingest
    p_ingest = subparsers.add_parser("ingest", help="Ingest files into vector store")
    p_ingest.add_argument("--path", required=True, help="File or directory to ingest")
    p_ingest.add_argument("--collection", default="default", help="Collection name")

    # search
    p_search = subparsers.add_parser("search", help="Semantic search")
    p_search.add_argument("--query", required=True, help="Search query")
    p_search.add_argument("--collection", default="default", help="Collection name")
    p_search.add_argument("--limit", type=int, default=5, help="Max results")

    # list
    subparsers.add_parser("list", help="List all collections")

    # delete
    p_delete = subparsers.add_parser("delete", help="Delete a collection")
    p_delete.add_argument("--collection", required=True, help="Collection to delete")

    # info
    p_info = subparsers.add_parser("info", help="Collection details")
    p_info.add_argument("--collection", default="default", help="Collection name")

    args = parser.parse_args()

    cmd_map = {
        "ingest": cmd_ingest,
        "search": cmd_search,
        "list": cmd_list,
        "delete": cmd_delete,
        "info": cmd_info,
    }

    try:
        result = cmd_map[args.command](args)
    except Exception as e:
        result = {"success": False, "error": f"{type(e).__name__}: {str(e)}"}

    print(json.dumps(result))
    sys.exit(0 if result.get("success") else 1)


if __name__ == "__main__":
    main()
