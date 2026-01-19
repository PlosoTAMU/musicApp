#!/usr/bin/env python3
"""
Simple HTTP server that wraps yt-dlp for iOS app communication.
Runs on your computer and iOS app connects to it over local network.

Usage:
    1. Install requirements: pip install yt-dlp
    2. Run: python server.py
    3. Note your computer's IP address (e.g., 192.168.1.100)
    4. In the iOS app, enter: 192.168.1.100:8765
"""

import http.server
import json
import os
import sys
import tempfile
import urllib.parse
import socket

# Port for the local server
PORT = 8765

class YTDLPHandler(http.server.BaseHTTPRequestHandler):
    """Handle requests for YouTube audio extraction."""
    
    def log_message(self, format, *args):
        """Log to stdout for debugging."""
        print(f"[yt-dlp-server] {args[0]}")
    
    def send_json(self, data, status=200):
        """Send JSON response."""
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())
    
    def send_file(self, filepath):
        """Send a file as response."""
        try:
            with open(filepath, 'rb') as f:
                data = f.read()
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', len(data))
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            self.send_json({'error': str(e)}, 500)
    
    def do_GET(self):
        """Handle GET requests."""
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        
        if parsed.path == '/health':
            self.send_json({'status': 'ok', 'version': '1.0'})
            
        elif parsed.path == '/info':
            # Get video info without downloading
            url = params.get('url', [None])[0]
            if not url:
                self.send_json({'error': 'Missing url parameter'}, 400)
                return
            
            try:
                info = self.get_video_info(url)
                self.send_json(info)
            except Exception as e:
                self.send_json({'error': str(e)}, 500)
                
        elif parsed.path == '/download':
            # Download audio and return file info
            url = params.get('url', [None])[0]
            
            if not url:
                self.send_json({'error': 'Missing url parameter'}, 400)
                return
            
            try:
                result = self.download_audio(url)
                self.send_json(result)
            except Exception as e:
                import traceback
                traceback.print_exc()
                self.send_json({'error': str(e)}, 500)
        
        elif parsed.path == '/file':
            # Serve a downloaded file
            filepath = params.get('path', [None])[0]
            if not filepath:
                self.send_json({'error': 'Missing path parameter'}, 400)
                return
            
            if os.path.exists(filepath):
                self.send_file(filepath)
            else:
                self.send_json({'error': 'File not found'}, 404)
        
        else:
            self.send_json({'error': 'Not found'}, 404)
    
    def do_OPTIONS(self):
        """Handle CORS preflight."""
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()
    
    def get_video_info(self, url):
        """Get video info using yt-dlp."""
        import yt_dlp
        
        ydl_opts = {
            'quiet': True,
            'no_warnings': True,
            'extract_flat': False,
        }
        
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=False)
            return {
                'title': info.get('title', 'Unknown'),
                'author': info.get('uploader', 'Unknown'),
                'duration': info.get('duration', 0),
                'thumbnail': info.get('thumbnail', ''),
                'id': info.get('id', ''),
            }
    
    def download_audio(self, url):
        """Download audio using yt-dlp."""
        import yt_dlp
        
        # Use temp directory
        output_dir = tempfile.mkdtemp(prefix='ytdlp_')
        output_template = os.path.join(output_dir, '%(title)s.%(ext)s')
        
        print(f"[yt-dlp-server] Downloading to: {output_dir}")
        
        # Try with audio extraction
        ydl_opts = {
            'format': 'bestaudio/best',
            'outtmpl': output_template,
            'quiet': False,
            'no_warnings': False,
            'postprocessors': [{
                'key': 'FFmpegExtractAudio',
                'preferredcodec': 'm4a',
                'preferredquality': '192',
            }],
        }
        
        downloaded_file = None
        title = None
        
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(url, download=True)
                title = info.get('title', 'audio')
                
            # Find the downloaded file
            for f in os.listdir(output_dir):
                filepath = os.path.join(output_dir, f)
                if os.path.isfile(filepath):
                    downloaded_file = filepath
                    break
                    
        except Exception as e:
            print(f"[yt-dlp-server] FFmpeg extraction failed: {e}")
            print("[yt-dlp-server] Trying without post-processing...")
            
            # Try without FFmpeg
            ydl_opts_simple = {
                'format': 'bestaudio/best',
                'outtmpl': output_template,
                'quiet': False,
            }
            
            with yt_dlp.YoutubeDL(ydl_opts_simple) as ydl:
                info = ydl.extract_info(url, download=True)
                title = info.get('title', 'audio')
            
            # Find the downloaded file
            for f in os.listdir(output_dir):
                filepath = os.path.join(output_dir, f)
                if os.path.isfile(filepath):
                    downloaded_file = filepath
                    break
        
        if downloaded_file:
            size = os.path.getsize(downloaded_file)
            print(f"[yt-dlp-server] Downloaded: {downloaded_file} ({size} bytes)")
            return {
                'success': True,
                'title': title,
                'filepath': downloaded_file,
                'size': size,
            }
        else:
            return {'error': 'Download completed but file not found'}


def get_local_ip():
    """Get the local IP address."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except:
        return "127.0.0.1"


def run_server():
    """Start the HTTP server."""
    # Bind to all interfaces so iOS can connect
    server = http.server.HTTPServer(('0.0.0.0', PORT), YTDLPHandler)
    
    local_ip = get_local_ip()
    print(f"""
╔══════════════════════════════════════════════════════════════╗
║                    yt-dlp Server for iOS                      ║
╠══════════════════════════════════════════════════════════════╣
║  Server running on:                                           ║
║    Local:   http://127.0.0.1:{PORT}                            ║
║    Network: http://{local_ip}:{PORT}                       ║
║                                                               ║
║  In your iOS app, enter this address:                         ║
║    {local_ip}:{PORT}                                       ║
║                                                               ║
║  Make sure your phone is on the same WiFi network!            ║
╚══════════════════════════════════════════════════════════════╝
""")
    
    server.serve_forever()


if __name__ == '__main__':
    # Check if yt-dlp is available
    try:
        import yt_dlp
        print(f"[yt-dlp-server] yt-dlp version: {yt_dlp.version.__version__}")
    except ImportError:
        print("[yt-dlp-server] ERROR: yt-dlp not installed.")
        print("[yt-dlp-server] Run: pip install yt-dlp")
        sys.exit(1)
    
    run_server()
