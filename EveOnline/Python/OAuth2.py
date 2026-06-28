import base64
import hashlib
import os
import requests
import time
import threading
import webbrowser
import csv # CSV file reader
import random
import sys
from curses import keyname
from pathlib import Path # file path
from datetime import datetime # DateTime
from http.server import HTTPServer, BaseHTTPRequestHandler
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
from collections import deque
from time import sleep
# ---------------------------------------------------------
#
# CONFIGURATION
#
# ---------------------------------------------------------
# Application secret and name
CLIENT_ID = "6e99142b1a1248c8b07550f2211c96be"
STATE = "AOW Market Login"
# Permission scopes required for then application access
SCOPES = "publicData esi-universe.read_structures.v1 esi-markets.structure_markets.v1"
# API Source data (Required)
SOURCE = "tranquility"
API = "latest"
# The callback URL for the authentication code
CALLBACK = "http://localhost/callback/"
# The folder we save data to
OUT_FOLDER = os.path.join(os.path.dirname(__file__).replace("Python", ""), "Data")
os.makedirs(OUT_FOLDER, exist_ok=True)
# Global token management data
TOKEN = None
TOKEN_EXPIRES = 0
# ---------------------------------------------------------
#
# FUNCTIONS
#
# ---------------------------------------------------------
# ---------------------------------------------------------
# PKCE HELPERS
# ---------------------------------------------------------
#
# def base64url_encode(data: bytes) -> str:
# Parameter:
#   data (bytes): Binary data to be encoded.
# Returns:
#   str: URL-safe Base64 encoded representation of the input data with
#   trailing '=' padding characters removed.
def base64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")
#
# def generate_pkce():
# Returns:
#   tuple[str, str]: A tuple containing the PKCE code verifier and its
#   corresponding SHA-256 code challenge, both encoded as URL-safe Base64
#   strings with trailing '=' padding removed.
def generate_pkce():
    # Generate a cryptographically secure random code verifier.
    verifier = base64url_encode(os.urandom(32))
    # Create a SHA-256 digest from the verifier.
    digest = hashlib.sha256(verifier.encode()).digest()
    # Convert the digest into a URL-safe Base64 encoded code challenge.
    challenge = base64url_encode(digest)
    # Return the verifier and its corresponding code challenge.
    return verifier, challenge
# ---------------------------------------------------------
# LOCAL HTTP LISTENER FOR AUTH CODE
# ---------------------------------------------------------
class OAuthHandler(BaseHTTPRequestHandler):
    # Stores the authorization code returned by the OAuth provider.
    auth_code = None
    # Signals when the authorization code has been received.
    auth_received = threading.Event()
    # Suppress error log messages
    def log_message(self, format, *args):
        pass   
    #
    # def do_GET(self):
    # Parameters:
    #   self (OAuthHandler): Instance handling the incoming HTTP GET request.
    # Returns:
    #   None: Extracts the OAuth authorization code from the callback URL,
    #   sends a confirmation response to the browser, and signals completion.
    def do_GET(self):
        # Check whether the callback request contains an authorization code.
        if "code=" in self.path:
            # Extract the query string from the callback URL.
            query = self.path.split("?", 1)[1]
            # Parse query string into key/value pairs.
            params = dict(q.split("=", 1) for q in query.split("&"))
            # Store the authorization code for retrieval by the caller.
            OAuthHandler.auth_code = params.get("code")
        # Send HTTP 200 response back to the browser.
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        # Display confirmation message in the browser.
        self.wfile.write(
            b"<html><body>Authentication successful. "
            b"You may now close this window.</body></html>"
        )
        # Flush response to ensure it is sent immediately.
        self.wfile.flush()
        # Signal that authentication flow is complete.
        OAuthHandler.auth_received.set()
        # Close the connection after response is delivered.
        self.close_connection = True
#        
# def get_auth_code(auth_url):
# Parameter:
#   auth_url (str): OAuth authorization URL opened in the user's browser.
# Returns:
#   str: Authorization code returned by the OAuth provider after
#   successful authentication and user consent.
def get_auth_code(auth_url):
    # Reset any previous authentication state.
    OAuthHandler.auth_code = None
    OAuthHandler.auth_received.clear()
    # Start local HTTP server to receive OAuth redirect callback.
    server = HTTPServer(("localhost", 80), OAuthHandler)
    # Process a single incoming request in a background thread.
    thread = threading.Thread(target=server.handle_request)
    thread.start()
    # Open the authorization URL in the user's default browser.
    webbrowser.open(auth_url)
    # Wait until the handler signals that authentication completed.
    OAuthHandler.auth_received.wait()
    # Close the server and release the socket.
    server.server_close()
    # Return the extracted authorization code.
    return OAuthHandler.auth_code
# ---------------------------------------------------------
# TOKEN MANAGEMENT
# ---------------------------------------------------------
#
# def refresh_token():
# Parameters:
#   None
# Returns:
#   None: Refreshes the global OAuth token using the stored refresh token,
#   updates the TOKEN dictionary with the new access credentials, and resets
#   the token expiration timestamp.
def refresh_token():
    global TOKEN, TOKEN_EXPIRES
    # OAuth token endpoint used to request refreshed credentials.
    url = "https://login.eveonline.com/v2/oauth/token/"
    # Request payload for refresh token flow.
    data = {
        "grant_type": "refresh_token",
        "refresh_token": TOKEN["refresh_token"],
        "client_id": CLIENT_ID,
    }
    # Send refresh request to OAuth provider.
    resp = requests.post(url, data=data)
    # Update global token storage with new credentials.
    TOKEN = resp.json()
    # Set new expiration time (15 minutes from now).
    TOKEN_EXPIRES = time.time() + 15 * 60
#
# def check_token():
# Parameters:
#   None
# Returns:
#   None: Ensures the current access token is valid, and refreshes it if expired.
def check_token():
    # If the current time exceeds token expiration, refresh credentials.
    if time.time() > TOKEN_EXPIRES:
        refresh_token()
# ---------------------------------------------------------
# MAIN AUTHENTICATION
# ---------------------------------------------------------
#
# def authenticate():
# Parameters:
#   None
# Returns:
#   None: Executes full OAuth authentication flow (PKCE + authorization code
#   exchange), stores access token globally, and sets token expiration time.
def authenticate():
    global TOKEN, TOKEN_EXPIRES
    # Generate PKCE verifier and corresponding challenge for secure OAuth flow.
    verifier, challenge = generate_pkce()
    # Construct OAuth authorization URL with required query parameters.
    auth_url = (
        "https://login.eveonline.com/v2/oauth/authorize/"
        f"?response_type=code"
        f"&redirect_uri={requests.utils.quote(CALLBACK)}"
        f"&client_id={CLIENT_ID}"
        f"&scope={requests.utils.quote(SCOPES)}"
        f"&code_challenge={challenge}"
        f"&code_challenge_method=S256"
        f"&state={requests.utils.quote(STATE)}"
    )
    # Open browser flow and wait for authorization code from callback server.
    code = get_auth_code(auth_url)
    # OAuth token endpoint for exchanging authorization code for access token.
    token_url = "https://login.eveonline.com/v2/oauth/token/"
    # Payload for authorization code exchange.
    data = {
        "grant_type": "authorization_code",
        "code": code,
        "client_id": CLIENT_ID,
        "code_verifier": verifier,
    }
    # Send token exchange request to OAuth provider.
    resp = requests.post(token_url, data=data)
    # Store returned token data globally.
    TOKEN = resp.json()
    # Set token expiration time (fixed 15-minute window).
    TOKEN_EXPIRES = time.time() + 15 * 60
# ---------------------------------------------------------
# DATA FUNCTIONS
# ---------------------------------------------------------
#
# def get_json_from_url(
# Parameters:
#   url (str): API endpoint to request JSON data from.
#   session (requests.Session | None): Optional reusable HTTP session for connection pooling.
#   max_retries (int): Maximum number of retry attempts for failed requests.
#   base_delay (int | float): Base delay (seconds) used for exponential backoff.
#   timeout (tuple): (connect_timeout, read_timeout) applied to HTTP request.
#   esi_safe_remain (int): Threshold for ESI error budget before triggering cooldown.
# Returns:
#   dict: Parsed JSON response from the API on success.
# Raises:
#   RuntimeError: If all retries fail or a fatal request error occurs.
def get_json_from_url(
    url,
    session=None,
    max_retries=10,
    base_delay=2,
    timeout=(10, 30),
    esi_safe_remain=10,
):
    # Create a new HTTP session if none is provided (enables connection reuse).
    if session is None:
        session = requests.Session()
    # HTTP status codes that are considered retryable.
    retryable_status = {420, 429, 500, 502, 503, 504,}
    # Attempt request up to the configured maximum number of retries.
    for attempt in range(1, max_retries + 1):
        try:
            check_token()
            myheader = {"Authorization": f"Bearer {TOKEN['access_token']}"}
            # Send HTTP GET request to the API endpoint.
            response = session.get(
                url,
                headers=myheader,
                timeout=timeout,
            )
            # Read ESI error budget headers (if provided by API).
            remain = response.headers.get("X-Esi-Error-Limit-Remain")
            reset = response.headers.get("X-Esi-Error-Limit-Reset")
            # If ESI rate-limit headers exist, evaluate remaining budget.
            if (remain is not None) and (reset is not None):
                try:
                    # Convert header values to integers.
                    remain = int(remain)
                    reset = int(reset)
                    # Trigger cooldown if error budget is low.
                    if remain <= esi_safe_remain:
                        # Calculate cooldown duration.
                        cooldown = reset + 1
                        # Inform user about enforced cooldown.
                        print(
                            f"[ESI PROTECTION] "
                            f"Remaining error budget low "
                            f"({remain}). "
                            f"Cooling down for "
                            f"{cooldown}s..."
                        )
                        # Pause execution to respect API limits.
                        sleep(cooldown)
                except ValueError:
                    # Ignore malformed header values.
                    pass
            # Successful request: return parsed JSON payload.
            if response.status_code == 200:
                return response.json()
            # Handle retryable HTTP errors.
            if response.status_code in retryable_status:
                # Extract server-provided retry delay if available.
                retry_after = response.headers.get("Retry-After")
                # Determine delay using server hint or exponential backoff.
                if retry_after:
                    try:
                        delay = int(retry_after)
                    except ValueError:
                        delay = base_delay * (2 ** (attempt - 1))
                else:
                    delay = base_delay * (2 ** (attempt - 1))
                # Add jitter to reduce synchronized retry behavior.
                delay += random.uniform(0, 1)
                # Log retry attempt and delay duration.
                print(
                    f"[Attempt {attempt}/{max_retries}] "
                    f"HTTP {response.status_code}. "
                    f"Retrying in {delay:.1f}s..."
                )
                # Wait before retrying request.
                sleep(delay)
                continue
            # Raise exception for non-retryable HTTP errors.
            response.raise_for_status()
        # Handle transient network-related errors with backoff retry.
        except (
            requests.exceptions.Timeout,
            requests.exceptions.ConnectionError,
            requests.exceptions.ChunkedEncodingError,
        ) as e:
            # Compute exponential backoff delay.
            delay = base_delay * (2 ** (attempt - 1))
            # Add randomness to prevent retry synchronization.
            delay += random.uniform(0, 1)
            # Log network failure and retry attempt.
            print(
                f"[Attempt {attempt}/{max_retries}] "
                f"Network error: {e}. "
                f"Retrying in {delay:.1f}s..."
            )
            # Wait before retrying request.
            sleep(delay)
        # Handle unrecoverable request errors.
        except requests.exceptions.RequestException as e:
            # Raise fatal error with context information.
            raise RuntimeError(
                f"Fatal API request failure.\n"
                f"URL: {url}\n"
                f"Error: {e}"
            ) from e
    # Exhausted all retries without success.
    raise RuntimeError(
        f"Failed after {max_retries} retries.\n"
        f"URL: {url}"
    )
# ---------------------------------------------------------
# BATCH PROCESSOR
# ---------------------------------------------------------
#
# def invoke_url_batch_processor(
# Parameters:
#   queue (iterable): Collection of job identifiers to be processed in batches.
#   job_block (callable): Worker function executed on each batch.
#   activity (str): Label used for progress display output.
#   max_jobs (int): Maximum number of concurrent worker threads.
#   batch_size (int): Number of items per processing batch.
#   max_retries (int): Maximum retry attempts for failed batches.
#   api (Any): Optional API/client object passed to worker function.
#   source (Any): Optional source/context passed to worker function.
# Returns:
#   dict: Aggregated results from all successfully processed batches.
def invoke_url_batch_processor(
    queue,
    job_block,
    activity="Processing",
    max_jobs=10,
    batch_size=50,
    max_retries=5,
    api=None,
    source=None,
):
    # Convert input queue into a FIFO structure for efficient batch popping.
    q = deque(queue)
    # Store original workload size for progress tracking.
    total = len(q)
    # Final aggregated output from all worker batches.
    results = {}
    # Track retry attempts per failed batch.
    retries = {}
    # Count successfully processed items.
    completed = 0
    #
    # Helper function to construct a batch from the queue.
    def make_batch():
        # Determine batch size without exceeding remaining items.
        size = min(batch_size, len(q))
        # Pop items from the queue to form a batch.
        return [q.popleft() for _ in range(size)]
    #
    # Create a thread pool for parallel batch processing.
    with ThreadPoolExecutor(max_workers=max_jobs) as pool:
        # Map futures to their corresponding batch for retry tracking.
        futures = {}
        # Make sure our token has not expired
        check_token()
        # Fill initial worker slots.
        while q and len(futures) < max_jobs:
            # Build a batch of items to process.
            batch = make_batch()
            # Submit batch job to thread pool.
            futures[pool.submit(job_block, batch, api, source, TOKEN)] = batch
        # Main processing loop: continue until all futures complete.
        while futures:
            # Wait until at least one future completes.
            done, _ = wait(futures, return_when=FIRST_COMPLETED)
            # Process completed futures.
            for future in done:
                # Retrieve associated batch and remove from tracking.
                batch = futures.pop(future)
                try:
                    # Get result from completed worker execution.
                    out = future.result()
                    # Merge batch output into global results.
                    if out:
                        results.update(out)
                        # Update completed item count.
                        completed += len(out)
                # Handle failed batch execution.
                except Exception:
                    # Create immutable identifier for retry tracking.
                    key = tuple(batch)
                    # Increment retry count for this batch.
                    retries[key] = retries.get(key, 0) + 1
                    # Retry batch if under retry limit.
                    if retries[key] <= max_retries:
                        print(
                            f"\n[WARN] Retrying batch "
                            f"({retries[key]}/{max_retries}): "
                            f"{batch}"
                        )
                        # Small delay before retry to reduce contention.
                        sleep(0.2)
                        # Make sure our token has not expired
                        check_token()
                        # Resubmit failed batch.
                        futures[pool.submit(job_block, batch, api, source, TOKEN)] = batch
                    else:
                        # Permanently fail batch after exceeding retry limit.
                        print(
                            f"\n[ERROR] "
                            f"Batch permanently failed: {batch}"
                        )
                # Immediately refill worker slot if queue still has items.
                if q:
                    # Build next batch.
                    new_batch = make_batch()
                    # Make sure our token has not expired
                    check_token()
                    # Submit next batch to maintain concurrency level.
                    futures[pool.submit(job_block, new_batch, api, source, TOKEN)] = new_batch
            # Compute completion percentage safely.
            pct = (
                min(100, int((completed / total) * 100))
                if total
                else 100
            )
            # Print live progress status.
            print(
                f"\r{activity} | "
                f"Completed: {completed}/{total} | "
                f"Running: {len(futures)} | "
                f"{pct}%  ",
                end="",
                flush=True,
            )
    # Return aggregated results after all batches complete.
    return results
# ---------------------------------------------------------
# CSV IMPORT/EXPORT
# ---------------------------------------------------------
#
# def get_FromCSV(filepath, IndexKey=None):
# Parameters:
#   filepath (str): Path to the CSV file to be read.
#   IndexKey (str | None): Optional column name used as the dictionary key.
#       If None, rows are indexed using a sequential counter.
# Returns:
#   dict: Nested dictionary representation of the CSV file where each row
#   is stored as a dictionary keyed either by row index or IndexKey value.
def get_FromCSV(filepath, IndexKey=None):
   # Log CSV load operation for traceability.
    print(f"Querying from {filepath}")
    # Container for parsed CSV data.
    csv_data = {}
    # Row counter used when no IndexKey is provided.
    rowctr = 1
    # Open CSV file safely with UTF-8 encoding.
    try:
        with open(filepath, mode='r', newline='', encoding='utf-8') as file:
            # Parse CSV into dictionaries using header row as keys.
            reader = csv.DictReader(file)
            # Iterate over each row in the CSV file.
            for row in reader:
                # Determine dictionary key for this row.
                if IndexKey is None:
                    # Use sequential row counter as key.
                    keyval = rowctr
                else:
                    # Use specified column value as dictionary key.
                    keyval = auto_cast(row[IndexKey])
                # Initialize row entry in output dictionary.
                csv_data[keyval] = {}
                # Convert and store each column value for the row.
                for key in row.keys():
                    # Apply type conversion where possible.
                    csv_data[keyval][key] = auto_cast(row[key])
                # Increment row counter for fallback indexing.
                rowctr += 1
    # Handle file I/O or parsing errors.
    except Exception as e:
        print(f"Error reading from CSV: {e}")
        sys.exit(1)
    # Return structured CSV data to caller.
    return csv_data
#
# def save_toCSV(filepath, data):
# Parameters:
#   filepath (str): Destination path where the CSV file will be written.
#   data (dict): Nested dictionary where each top-level key represents a row,
#       and each value is a dictionary of column name -> value pairs.
# Returns:
#   None: Writes structured dictionary data to a CSV file.
def save_toCSV(filepath, data):
    # Open file in write mode with UTF-8 encoding.
    with open(filepath, 'w', encoding="utf-8", newline='') as f:
        # Track whether header has been written.
        linectr = 0
        # Iterate over each row in the dataset.
        for mainkey in data.keys():
            # Write CSV header using the first row's keys.
            if linectr == 0:
                # Extract column names and write header row.
                f.write("\"" + "\",\"".join(data[mainkey].keys()) + "\"\n")
            # Convert row values into CSV-formatted string.
            line = ",".join(
                f'"{v}"' if isinstance(v, str) else str(v)
                for v in data[mainkey].values()
            )
            # Write formatted row to file.
            f.write(line + "\n")
            # Increment row counter after writing each line.
            linectr += 1#
# ---------------------------------------------------------
# DATA CONVERSION, TYPING
# ---------------------------------------------------------
#
# def auto_cast(value):
# Parameters:
#   value (Any): Input value, typically a string from CSV or external text source.
# Returns:
#   int | float | str | None: Attempts to convert the input into the most
#   appropriate primitive type (int, float, or str). Returns None or empty
#   string if those are explicitly provided.
def auto_cast(value):
    # Preserve None values as-is.
    if value is None:
        return None
    # Remove leading/trailing whitespace for consistent parsing.
    value = value.strip()
    # Preserve explicit empty string values.
    if value == "":
        return ""
    # Attempt integer conversion first (strictest numeric type).
    try:
        return int(value)
    except ValueError:
        pass
    # Attempt floating-point conversion if integer conversion fails.
    try:
        return float(value)
    except ValueError:
        # Fall back to original string if no numeric conversion is possible.
        return value#
# ---------------------------------------------------------
#
# END FUNCTIONS
#
# ---------------------------------------------------------
#
# Clear the terminal screen (ANSI)
print("\033[H\033[J", end="")
# Get current date and time
starttime = datetime.now()
formatted_now = starttime.strftime("%Y-%m-%d %H:%M:%S")
# Announce start
print("Process started:", formatted_now)
# Authenticate to the API
print("Authenticating with EVE SSO...")
authenticate()
#
# ---------------------------------------------------------
# FETCH STRUCTURE ID LIST
# ---------------------------------------------------------
url = f"https://esi.evetech.net/{API}/universe/structures/?datasource={SOURCE}"
structureids = get_json_from_url (url, None, 5, 10, (10,30), 10)
# ---------------------------------------------------------
# JOB WORKER FOR EACH STRUCTURE
# ---------------------------------------------------------
def structure_job(batch, api, source, token):
    # Create a persistent session that we can re-use to save on reconnection times
    session = requests.Session()
    # Initialize our Dict to hold the results
    out = {}
    # Process each station id in the batch
    for structure_id in batch:
        # Form the URL
        url = (
            f"https://esi.evetech.net/"
            f"{api}/universe/structures/"
            f"{structure_id}/"
            f"?datasource={source}&language=en"
        )
        # Retry up to 5 times if we have to
        max_retries = 5
        # Keep attempting until we succeed or run out of retries
        for attempt in range(max_retries):
            # Trap and handle any errors
            try:
                # Create the header
                myheader = {"Authorization": f"Bearer {token['access_token']}"}
                # Get the data from the API
                response = session.get(url, timeout=30, headers=myheader)
                # Handle ESI throttling
                if response.status_code in (420, 429):
                    # Use Retry-After if available
                    retry_after = response.headers.get("Retry-After")
                    # If there was no retry-after
                    if retry_after is not None:
                        delay = int(retry_after)
                    else:
                        # Exponential backoff
                        delay = min(2 ** attempt, 30)
                    # Alert the user
                    print(
                        f"\n[WARN] "
                        f"ESI throttle {response.status_code} "
                        f"for {structure_id} "
                        f"(attempt {attempt + 1}/{max_retries}) "
                        f"sleeping {delay}s"
                    )
                    # Wait for things to stabilize
                    sleep(delay)
                    # Skip past the rest of the loop processing
                    continue
                # Raise all other HTTP failures
                response.raise_for_status()
                # Get the JSON data from the request
                data = response.json()
                structure_id = int(structure_id)
                # Build our output Dict
                out[structure_id] = {
                    "ID": structure_id,
                    "Name": data["name"],
                    "SystemID": int(data["solar_system_id"])
                }
                # Success
                break
            # Error handling
            except requests.RequestException as e:
                # Final failure
                if attempt == max_retries - 1:
                    # Generate a runtime error
                    raise RuntimeError(
                        f"Failed system {structure_id}"
                    ) from e
                # Exponential retry backoff
                delay = min(2 ** attempt, 30)
                # Warn the user
                print(
                    f"\n[WARN] "
                    f"Request failure for {structure_id} "
                    f"(attempt {attempt + 1}/{max_retries}) "
                    f"sleeping {delay}s"
                )
                # Wait for a bit for things to stabilize
                sleep(delay)
    # Send the final results back to the caller
    return out
# ---------------------------------------------------------
# EXECUTE
# ---------------------------------------------------------
# Invoke the batch processor
structures = invoke_url_batch_processor(
    queue=structureids,
    job_block=structure_job,
    activity="Loading Structures",
    max_jobs=10,
    batch_size=50,
    api=API,
    source=SOURCE,
)
# Create the filename
thisfile = OUT_FOLDER + "\Structures.csv"
# Save the structures to CSV.
save_toCSV(thisfile, structures)
# Go to the next line to preserve to progress bar
print("")
# Annouce completion
print("Done.")