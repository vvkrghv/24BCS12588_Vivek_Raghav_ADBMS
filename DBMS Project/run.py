import os

from app import create_app

app = create_app()

if __name__ == "__main__":
    # set FLASK_DEBUG=1 in .env only while developing; never show debug pages to users
    app.run(debug=os.environ.get("FLASK_DEBUG") == "1", port=5000)
