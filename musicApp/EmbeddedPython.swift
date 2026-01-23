private func generateYtdlpScript(url: String, outputDir: String, resultFilePath: String, logFilePath: String) -> String {
    let cleanURL = url.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
    
    return """
    import sys
    import os
    import json
    
    log_file = r'''\(logFilePath)'''
    def log(msg):
        try:
            with open(log_file, 'a', encoding='utf-8') as f:
                f.write(str(msg) + '\\n')
                f.flush()  # Force write immediately
            # Also print to stdout/stderr so Xcode console gets it
            print(msg, flush=True)
        except Exception as e:
            print(f'Log error: {e}', flush=True)
    
    # Redirect stdout and stderr to log file
    class TeeOutput:
        def __init__(self, log_func):
            self.log_func = log_func
            
        def write(self, message):
            if message.strip():
                self.log_func(message.rstrip())
                
        def flush(self):
            pass
    
    sys.stdout = TeeOutput(log)
    sys.stderr = TeeOutput(log)
    
    log('=== yt-dlp Debug Log ===')
    log(f'Python version: {sys.version}')
    log(f'URL: \(cleanURL)')
    
    try:
        import yt_dlp
        log(f'yt_dlp imported successfully')
        log(f'yt_dlp version: {yt_dlp.version.__version__}')
    except Exception as e:
        log(f'Failed to import yt_dlp: {e}')
        result = {'success': False, 'error': f'Failed to import yt_dlp: {e}'}
        with open(r'''\(resultFilePath)''', 'w', encoding='utf-8') as f:
            json.dump(result, f)
        raise
    
    output_dir = r'''\(outputDir)'''
    url = r'''\(cleanURL)'''
    os.makedirs(output_dir, exist_ok=True)
    log(f'Output directory: {output_dir}')
    
    # SPEED OPTIMIZATIONS while keeping format fallbacks
    ydl_opts = {
        'format': '140/bestaudio[ext=m4a]/bestaudio/best',
        'user_agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'quiet': False,
        'verbose': True,  # Enable verbose output
        'noplaylist': True,
        'outtmpl': os.path.join(output_dir, '%(id)s.%(ext)s'),
        'extractor_args': {
            'youtube': {
                'player_client': ['ios', 'android'],
                'skip': ['web'],
            }
        },
        'merge_output_format': 'm4a',
        'http_chunk_size': 10485760,
        'retries': 3,
        'fragment_retries': 1,
        'skip_unavailable_fragments': True,
        'socket_timeout': 20,
        'noprogress': False,  # Show progress in logs
        'no_color': True,
        'nocheckcertificate': True,
        'logger': type('Logger', (), {
            'debug': lambda self, msg: log(f'[DEBUG] {msg}'),
            'info': lambda self, msg: log(f'[INFO] {msg}'),
            'warning': lambda self, msg: log(f'[WARNING] {msg}'),
            'error': lambda self, msg: log(f'[ERROR] {msg}'),
        })(),
    }
    
    result = {}
    try:
        log('Creating YoutubeDL instance...')
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            log('Extracting info...')
            info = ydl.extract_info(url, download=False)
            title = info.get('title', 'Unknown')
            video_id = info.get('id', 'unknown')
            log(f'Title: {title}')
            log(f'Video ID: {video_id}')
            
            # Get best thumbnail
            thumbnail_url = None
            thumbnails = info.get('thumbnails', [])
            if thumbnails:
                thumbnail_url = thumbnails[-1].get('url')
            else:
                thumbnail_url = f'https://img.youtube.com/vi/{video_id}/maxresdefault.jpg'
            
            log(f'Thumbnail URL: {thumbnail_url}')
            
            # Now download
            log('Starting download...')
            info = ydl.extract_info(url, download=True)
            downloaded_path = ydl.prepare_filename(info)
            
            log(f'Downloaded to: {downloaded_path}')
            
            if os.path.exists(downloaded_path):
                file_size = os.path.getsize(downloaded_path)
                log(f'File size: {file_size} bytes ({file_size / 1024 / 1024:.2f} MB)')
                
                # Ensure M4A extension
                if not downloaded_path.endswith('.m4a'):
                    m4a_path = os.path.splitext(downloaded_path)[0] + '.m4a'
                    log(f'Renaming to: {m4a_path}')
                    try:
                        os.rename(downloaded_path, m4a_path)
                        downloaded_path = m4a_path
                        log('Rename successful')
                    except Exception as e:
                        log(f'Rename failed: {e}')
                
                result = {
                    'success': True,
                    'title': title,
                    'audio_url': downloaded_path,
                    'audio_ext': 'm4a',
                    'thumbnail': thumbnail_url,
                }
                log('Download completed successfully!')
            else:
                log('ERROR: File not found after download')
                result = {'success': False, 'error': 'File not found after download'}
                
    except Exception as e:
        log(f'Exception occurred: {e}')
        import traceback
        log('Traceback:')
        log(traceback.format_exc())
        result = {'success': False, 'error': str(e)}
    
    log('Writing result file...')
    with open(r'''\(resultFilePath)''', 'w', encoding='utf-8') as f:
        json.dump(result, f)
    log('Done!')
    """
}