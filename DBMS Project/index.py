"""Entry point used by Vercel (it looks for a Flask `app` object in index.py)."""
from app import create_app

app = create_app()
