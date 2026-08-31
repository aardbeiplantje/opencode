import os
import asyncio
import httpx
from mcp.server.stdio import stdio_server
from fastmcp import FastMCP

SEARXNG_URL = os.getenv("SEARXNG_URL", "http://localhost:8080")

mcp = FastMCP("searxng")


@mcp.tool()
async def web_search(query: str, categories: str = "general", language: str = "en", safesearch: int = 1, time_range: str = ""):
    """Search the web using SearXNG
    
    Args:
        query: The search query
        categories: Comma-separated categories (general, images, videos, news, it, science, map, music, files, social media, etc.)
        language: Language code (e.g., en, de, fr)
        safesearch: 0=off, 1=moderate, 2=strict
        time_range: Time range filter (day, week, month, year)
    """
    params = {
        "q": query,
        "categories": categories,
        "language": language,
        "safesearch": safesearch,
        "format": "json"
    }
    if time_range:
        params["time_range"] = time_range

    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.get(f"{SEARXNG_URL}/search", params=params)
        response.raise_for_status()
        data = response.json()

    results = data.get("results", [])
    if not results:
        return "No results found"

    formatted = []
    for r in results[:10]:
        title = r.get("title", "")
        url = r.get("url", "")
        content = r.get("content", "")
        formatted.append(f"Title: {title}\nURL: {url}\nSnippet: {content}\n")

    return "\n---\n".join(formatted)


@mcp.tool()
async def search_news(query: str, language: str = "en"):
    """Search for news articles using SearXNG"""
    return await web_search(query, categories="news", language=language)


@mcp.tool()
async def search_images(query: str, language: str = "en", safesearch: int = 1):
    """Search for images using SearXNG"""
    return await web_search(query, categories="images", language=language, safesearch=safesearch)


@mcp.tool()
async def search_videos(query: str, language: str = "en", safesearch: int = 1):
    """Search for videos using SearXNG"""
    return await web_search(query, categories="videos", language=language, safesearch=safesearch)


@mcp.tool()
async def search_it(query: str, language: str = "en", safesearch: int = 1):
    """Search for IT/technology content using SearXNG"""
    return await web_search(query, categories="it", language=language, safesearch=safesearch)


@mcp.tool()
async def search_science(query: str, language: str = "en", safesearch: int = 1):
    """Search for science content using SearXNG"""
    return await web_search(query, categories="science", language=language, safesearch=safesearch)


@mcp.tool()
async def search_map(query: str, language: str = "en", safesearch: int = 1):
    """Search for maps/locations using SearXNG"""
    return await web_search(query, categories="map", language=language, safesearch=safesearch)


@mcp.tool()
async def search_music(query: str, language: str = "en", safesearch: int = 1):
    """Search for music using SearXNG"""
    return await web_search(query, categories="music", language=language, safesearch=safesearch)


@mcp.tool()
async def search_files(query: str, language: str = "en", safesearch: int = 1):
    """Search for files/documents using SearXNG"""
    return await web_search(query, categories="files", language=language, safesearch=safesearch)


@mcp.tool()
async def search_social_media(query: str, language: str = "en", safesearch: int = 1):
    """Search social media using SearXNG"""
    return await web_search(query, categories="social media", language=language, safesearch=safesearch)


if __name__ == "__main__":
    mcp.run()