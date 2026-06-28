"""
GetData.py



Revisions:
2026-04-25 - Initial release

Requires:   Requests module (python -m pip install requests)
"""
#-------------------------------------------------------------------------
#
# MODULES
#
#-------------------------------------------------------------------------
#
# Load the required modules
from curses import keyname
import os
import sys
import csv # CSV file reader
import random
import requests # HTTP requests
#import pandas as pd # Data manipulation and analysis
# import numpy as np # Arrays and data manipulation
from pathlib import Path # file path
from datetime import datetime # DateTime
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
from collections import deque
from time import sleep
#
#-------------------------------------------------------------------------
#
# CONFIGURATION
#
#-------------------------------------------------------------------------
#
# Source
source = "tranquility"
api = "latest"
# Data folder
datafolder = '../Data/'
# Request headers
myheader = {"Content-Type": "application/json"}
#
#-------------------------------------------------------------------------
#
# Functions
#
#-------------------------------------------------------------------------
#
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
    # If no session was passed, create one to use
    if session is None:
        session = requests.Session()
    # These errors can be retried.
    retryable_status = {420,429,500,502,503,504,}
    # Allow up to the maximum specified number of retries
    for attempt in range(1, max_retries + 1):
        try:
            # Call the API to get the data
            response = session.get(url,headers=myheader,timeout=timeout,)
            # Check and return the values from an ESI 420 repose
            remain = response.headers.get("X-Esi-Error-Limit-Remain")
            reset = response.headers.get("X-Esi-Error-Limit-Reset")
            # If the headers are present, we need to fall back and wait
            if (remain is not None) and (reset is not None):
                try:
                    # Convert the header response to integers
                    remain = int(remain)
                    reset = int(reset)
                    # Near ESI lockout threshold
                    if remain <= esi_safe_remain:
                        # Add a second to the cooldown
                        cooldown = reset + 1
                        # Warn the user
                        print(
                            f"[ESI PROTECTION] "
                            f"Remaining error budget low "
                            f"({remain}). "
                            f"Cooling down for "
                            f"{cooldown}s..."
                        )
                        # Wait for the sepcified number of seconds
                        sleep(cooldown)
                except ValueError:
                    pass
            # If we got a success status, return the json response
            if response.status_code == 200:
                return response.json()
            # If we got a retryable error status
            if response.status_code in retryable_status:
                # See if we can get the retry-after value from the response header
                retry_after = response.headers.get("Retry-After")
                # If we did get it
                if retry_after:
                    # Try to convert it to an integer, otherwise use an exponential backoff
                    try:
                        delay = int(retry_after)
                    except ValueError:
                        delay = base_delay * (2 ** (attempt - 1))
                # If not, use an exponential backoff
                else:
                    delay = base_delay * (2 ** (attempt - 1))
                # Add a bit of randomness to the delay
                delay += random.uniform(0, 1)
                # Warn the user
                print(
                    f"[Attempt {attempt}/{max_retries}] "
                    f"HTTP {response.status_code}. "
                    f"Retrying in {delay:.1f}s..."
                )
                # Wait a bit to allow things to stabilize
                sleep(delay)
                # Go back to the start of the loop and try again, bypassing the rest of this code
                continue
            # Raise an exception for non-retryable errors
            response.raise_for_status()
        # For these errors, retry with an exponential fallback
        except (
            requests.exceptions.Timeout,
            requests.exceptions.ConnectionError,
            requests.exceptions.ChunkedEncodingError,
        ) as e:
            # Calculate the fallback delay
            delay = base_delay * (2 ** (attempt - 1))
            # Add a bit of randomness
            delay += random.uniform(0, 1)
            # Warn the user
            print(
                f"[Attempt {attempt}/{max_retries}] "
                f"Network error: {e}. "
                f"Retrying in {delay:.1f}s..."
            )
            # Wait a bit for things to stabilize
            sleep(delay)
        # Handle any fatal errors
        except requests.exceptions.RequestException as e:
            # Raise a runtime error
            raise RuntimeError(
                f"Fatal API request failure.\n"
                f"URL: {url}\n"
                f"Error: {e}"
            ) from e
    # Retries are exhausted, raise a runtime error
    raise RuntimeError(
        f"Failed after {max_retries} retries.\n"
        f"URL: {url}"
    )
# ---------------------------------------------------------
# BATCH PROCESSOR
# ---------------------------------------------------------
#
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
    # Fast FIFO queue
    q = deque(queue)
    # Preserve original workload size
    total = len(q)
    # Final output dictionary
    results = {}
    # Retry tracking
    retries = {}
    # Completion tracking
    completed = 0
    # Efficient batch builder
    def make_batch():
        size = min(batch_size, len(q))
        return [q.popleft() for _ in range(size)]
    # Create a pool of thread workers that will process in parallel
    with ThreadPoolExecutor(max_workers=max_jobs) as pool:
        # future -> batch mapping, creates a Dict with the key as the running job and the batch of id's to process as a value
        # This allows for failed job restarts
        futures = {}
        # Initial worker fill
        while q and len(futures) < max_jobs:
            # Make the batch list of id's we need to process
            batch = make_batch()
            # Submit the job to the pool, passing the necessary parameters
            futures[pool.submit(job_block, batch, api, source)] = batch
        # Main processing loop (Keep processing while we have jobs to process)
        while futures:
            # Wait for at least one completion.
            # Wait returns two sets, completed jobs and not completed jobs. We only care about the completed jobs
            # and store them in Done, ignoring the second set.
            done, _ = wait(futures,return_when=FIRST_COMPLETED)
            # Process completed jobs
            for future in done:
                # Retrieve the value (batch) associated with the job and remove it from the futures Dict
                batch = futures.pop(future)
                try:
                    # Retrieve the Dict result from the completed job
                    out = future.result()
                    # Merge the returned dictionary with the master dictionary
                    if out:
                        results.update(out)
                        # Increment our counter of completed batch id's
                        completed += len(out)
                # Handle any exceptions
                except Exception:
                    # Create an immutable identifier representing this batch so it can be tracked in dictionaries or sets.
                    key = tuple(batch)
                    # Increase the retry count for this key by 1. If the key does not exist yet, start it at 0 first.
                    retries[key] = retries.get(key, 0) + 1
                    # Retry if allowed
                    if retries[key] <= max_retries:
                        print(
                            f"\n[WARN] Retrying batch "
                            f"({retries[key]}/{max_retries}): "
                            f"{batch}"
                        )
                        # Wait a little bit for things to stabilize
                        sleep(0.2)
                        # Submit the retry job to the pool
                        futures[pool.submit(job_block,batch,api,source,)] = batch
                    # The job has hit max retries
                    else:
                        print(
                            f"\n[ERROR] "
                            f"Batch permanently failed: {batch}"
                        )
                # Refill worker slot immediately if there are any items left in the queue
                if q:
                    # Create the new batch
                    new_batch = make_batch()
                    # Submit the new job to the pool
                    futures[pool.submit(job_block,new_batch,api,source,)] = new_batch
            # If total exists and is non-zero, calculate the percentage completed. Otherwise, set the percentage to 100.
            pct = (
                min(100, int((completed / total) * 100))
                if total
                else 100
            )
            # Display the progress bar
            print(
                f"\r{activity} | "
                f"Completed: {completed}/{total} | "
                f"Running: {len(futures)} | "
                f"{pct}%",
                end="",
                flush=True,
            )
    # Return the master dictionary data back to the caller
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
def get_FromCSV(filepath, IndexKey = None):
   # Announce the action
    print(f"Querying from {filepath}")
    # Create the Dict to hold the CSV data
    csv_data = {}
    # Initialize our row counter
    rowctr = 1    
    # Open the file
    try:
        with open(filepath, mode='r', newline='', encoding='utf-8') as file:
            # This gives us a Dict with the column headers as keys, and the row data as values.
            reader = csv.DictReader(file)
            # Iterate through each row
            for row in reader:
                if IndexKey is None:
                    # Use the row counter as the key for the csv_data dictionary
                    keyval = rowctr                        
                else:
                    # Use the value of the IndexKey column as the key for the csv_data dictionary
                    keyval = auto_cast(row[IndexKey])
                # Create the dictionary for this row
                csv_data[keyval] = {}
                # Iterate through all the keys in the row
                for key in row.keys():
                    # Add the data to the csv_data dictionary, using auto_cast to convert numeric values to the appropriate type
                    csv_data[keyval][key] = auto_cast(row[key])
                # Increment the row counter
                rowctr += 1
    except Exception as e:
        print(f"Error reading from CSV: {e}")
        sys.exit(1)
    # And send it back to the caller
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
    # Output the API data to the CSV 
    with open(filepath, 'w', encoding="utf-8", newline='') as f:
        # Initialize the line counter
        linectr = 0
        # Iterate through the data dictionary items
        for mainkey in data.keys():
            # If this is the first line, write the header
            if linectr == 0:
                # Write the header line
                f.write("\"" + "\",\"".join(data[mainkey].keys()) + "\"\n")
            # Write the data line
            line = ",".join(
                f'"{v}"' if isinstance(v, str) else str(v)
                for v in data[mainkey].values()
            )
            f.write(line + "\n")
            # Increment the line counter
            linectr += 1
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
    if value is None:
        return None
    value = value.strip()
    if value == "":
        return ""
    try:
        return int(value)
    except ValueError:
        pass
    try:
        return float(value)
    except ValueError:
        return value
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
#
"""
Get the Structure list.

Access to privately owned structures can vary based on the user.
It is necessary to use the OAuth script to produce this inventory,
but the data is required for our purposes in this script.

Thus, the only source is the CSV result of the OAUTH script.
"""
# Create the dictionary to contain the dictionary entries for each structure.
structures = {}
# Set the full path to the CSV file
thisfile = datafolder + "Structures.csv"
# Check if the Structures CSV file exists
if Path(thisfile).exists():
    # Announce the action
    print("Querying Structures from CSV...")
    # Read the csv data
    structures = get_FromCSV(thisfile, "ID")
else:
    print("Structures data not found. Please run the OAUTH script to generate the Structures.csv file.")
    sys.exit(1)
"""
Get the Region list.

Regions are rarely added or removed in Eve Online. We will re-use
the existing CSV data, or create it from the Eve Online REST API
if we need to.
"""
# Create the list to hold the Regions dictionary items
regions = {}
# Specify the expected full path to the CSSV file
thisfile = datafolder + "Regions.csv"
# Check if the Regions CSV file exists.
if Path(thisfile).exists():
    # Announce the action
    print("Querying Regions from CSV...")
    # Read the csv data
    regions = get_FromCSV(thisfile, "ID")
else:
    # Announce the action
    print("Querying Regions from API...")
    # Get the URL to list all region ID's from the API
    url = "https://esi.evetech.net/" + api + "/universe/regions/?datasource=" + source
    # Populate the regionids dictionary with the API data
    regionids = get_json_from_url(url,None,10,2,(10,30),10)
    # ---------------------------------------------------------
    # Worker
    # ---------------------------------------------------------
    def region_job(batch, api, source):
        # Create a persistent session that we can re-use to save on reconnection times
        session = requests.Session()
        # Initialize our Dict to hold the results
        out = {}
        # Process each region id in the batch
        for region_id in batch:
            # Form the URL
            url = (
                f"https://esi.evetech.net/"
                f"{api}/universe/regions/"
                f"{region_id}/"
                f"?datasource={source}&language=en"
            )
            # Retry up to 5 times if we have to
            max_retries = 5
            # Keep attempting until we succeed or run out of retries
            for attempt in range(max_retries):
                # Trap and handle any errors
                try:
                    # Get the data from the API
                    response = session.get(url, timeout=30)
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
                            f"for {region_id} "
                            f"(attempt {attempt + 1}/{max_retries}) "
                            f"sleeping {delay}s"
                        )
                        # Wait for things to stabilize
                        sleep(delay)
                        # Skip past the rest of the loop processing
                        continue
                    # Raise an exception for all other HTTP failures
                    response.raise_for_status()
                    # Get the JSON data from the request
                    data = response.json()
                    # Build our output Dict
                    out[int(region_id)] = {
                        "ID": int(region_id),
                        "Region": data["name"],
                    }
                    # Success
                    break
                # Error handling
                except requests.RequestException as e:
                    # Final failure
                    if attempt == max_retries - 1:
                        # Generate a runtime error
                        raise RuntimeError(
                            f"Failed region {region_id}"
                        ) from e
                    # Exponential retry backoff
                    delay = min(2 ** attempt, 30)
                    # Warn the user
                    print(
                        f"\n[WARN] "
                        f"Request failure for {region_id} "
                        f"(attempt {attempt + 1}/{max_retries}) "
                        f"sleeping {delay}s"
                    )
                    # Wait for a bit for things to stabilize
                    sleep(delay)
        # Send the final results back to the caller
        return out
    # ---------------------------------------------------------
    # Execute
    # ---------------------------------------------------------
    # Invoke the batch processor
    regions = invoke_url_batch_processor(
        queue=regionids,
        job_block=region_job,
        activity="Loading Regions",
        max_jobs=10,
        batch_size=50,
        api=api,
        source=source,
    )
    # Save the regions to CSV.
    save_toCSV(thisfile, regions)
    # Go to the next line to preserve to progress bar
    print("")
#
"""
Get the Systems list.

Systems are rarely added or removed in Eve Online. We will re-use
the existing CSV data, or create it from the Eve Online REST API
if we need to.
"""
# Create the list to hold the Systems dictionary items
systems = {}
# Specify the full path to the expected CSV
thisfile = datafolder + "Systems.csv"
# Check if the Systems CSV file exists.
if Path(thisfile).exists():
    # Announce the action
    print("Querying Systems from CSV...")
     # Read the csv data
    systems = get_FromCSV(thisfile, "ID")
else:
    # Announce the action
    print("Querying Systems from API...")
    # Get the URL to list all system ID's from the API
    url = "https://esi.evetech.net/" + api + "/universe/systems/?datasource=" + source
    # Populate the systemids dictionary with the API data
    systemids = get_json_from_url(url,None,10,2,(10,30),10)
    # ---------------------------------------------------------
    # Worker
    # ---------------------------------------------------------
    def system_job(batch, api, source):
        # Create a persistent session that we can re-use to save on reconnection times
        session = requests.Session()
        # Initialize our Dict to hold the results
        out = {}
        # Process each region id in the batch
        for system_id in batch:
            # Form the URL
            url = (
                f"https://esi.evetech.net/"
                f"{api}/universe/systems/"
                f"{system_id}/"
                f"?datasource={source}&language=en"
            )
            # Retry up to 5 times if we have to
            max_retries = 5
            # Keep attempting until we succeed or run out of retries
            for attempt in range(max_retries):
                # Trap and handle any errors
                try:
                    # Get the data from the API
                    response = session.get(url, timeout=30)
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
                            f"for {system_id} "
                            f"(attempt {attempt + 1}/{max_retries}) "
                            f"sleeping {delay}s"
                        )
                        # Wait for things to stabilize
                        sleep(delay)
                        # Skip past the rest of the loop processing
                        continue
                    # Raise an exception for all other HTTP failures
                    response.raise_for_status()
                    # Get the JSON data from the request
                    data = response.json()
                    # Build our output Dict
                    out[int(system_id)] = {
                        "ID": int(system_id),
                        "System": data["name"],
                        "security_status": float(data["security_status"])
                    }
                    # Success
                    break
                # Error handling
                except requests.RequestException as e:
                    # Final failure
                    if attempt == max_retries - 1:
                        # Generate a runtime error
                        raise RuntimeError(
                            f"Failed system {system_id}"
                        ) from e
                    # Exponential retry backoff
                    delay = min(2 ** attempt, 30)
                    # Warn the user
                    print(
                        f"\n[WARN] "
                        f"Request failure for {system_id} "
                        f"(attempt {attempt + 1}/{max_retries}) "
                        f"sleeping {delay}s"
                    )
                    # Wait for a bit for things to stabilize
                    sleep(delay)
        # Send the final results back to the caller
        return out
    # ---------------------------------------------------------
    # Execute
    # ---------------------------------------------------------
    # Invoke the batch processor
    systems = invoke_url_batch_processor(
        queue=systemids,
        job_block=system_job,
        activity="Loading Systems",
        max_jobs=4,
        batch_size=100,
        api=api,
        source=source,
    )
    # Save the systems to CSV.
    save_toCSV(thisfile, systems)
    # Go to the next line to preserve the progress bar
    print("")
"""
Get the Types list.

Types are rarely added or removed in Eve Online. We will re-use
the existing CSV data, or create it from the Eve Online REST API
if we need to. 

This data is updated as type ids are found to be missing. Incremental
updates save a lot of time.
"""
# Create the Types dictionary
Types = {}
# Specify the full path for the expected CSV
thisfile = datafolder + "Types.csv"
# Check if the Types CSV exists
if Path(thisfile).exists():
    # Announce the action
    print("Querying Types from CSV...")
    # Existing cached type records
    Types = get_FromCSV(thisfile, "ID")
# ---------------------------------------------------------
# Query ESI Type IDs
# ---------------------------------------------------------
# Announce the action
print("Querying Types from API...")
# First page request to get X-Pages (pages to query) from the header
url = (
    f"https://esi.evetech.net/"
    f"{api}/universe/types/"
    f"?datasource={source}&page=1"
)
# Query the API
response = requests.get(url, headers=myheader, timeout=(10, 20))
# Raise an exception for any error
response.raise_for_status()
# Total page count
maxpages = int(response.headers.get("X-Pages", 1))
# Create a shared HTTP session
session = requests.Session()
# Master dictionary of all IDs from ESI
AllTypeIDs = {}
# Query every page
for page in range(1, maxpages + 1):
    # Form the URL
    url = (
        f"https://esi.evetech.net/"
        f"{api}/universe/types/"
        f"?datasource={source}&page={page}"
    )
    # Retrieve page of type IDs
    typeids = get_json_from_url(url,session,10,2,(10,30),10)
    # Append IDs into master dict
    AllTypeIDs.update(
        {
            int(typeid): {
                "ID": int(typeid)
            }
            for typeid in typeids
        }
    )
    # Progress bar
    print(
        f"\rLoaded page {page}/{maxpages} "
        f"({len(AllTypeIDs)} IDs)",
        end="",
        flush=True,
    )
# ---------------------------------------------------------
# Build MissingTypes
# ---------------------------------------------------------
# Existing cached IDs
existing_ids = set(Types.keys())
# All IDs currently in ESI
api_ids = set(AllTypeIDs.keys())
# IDs missing locally
missing_ids = api_ids - existing_ids
# Final dictionary of missing types
MissingTypes = {
    typeid: AllTypeIDs[typeid]
    for typeid in missing_ids
}
# Announce the result
print(f"\nFound {len(MissingTypes)} missing types.")
# Only process if we have Missing Types
if (len(MissingTypes) > 0):
    # ---------------------------------------------------------
    # Worker
    # ---------------------------------------------------------
    def type_job(batch, api, source):
        # Create a persistent session that we can re-use to save on reconnection times
        session = requests.Session()
        # Initialize our Dict to hold the results
        out = {}
        # Process each region id in the batch
        for type_id in batch:
            # Form the URL
            url = (
                f"https://esi.evetech.net/"
                f"{api}/universe/types/"
                f"{type_id}/"
                f"?datasource={source}&language=en"
            )
            # Retry up to 5 times if we have to
            max_retries = 5
            # Keep attempting until we succeed or run out of retries
            for attempt in range(max_retries):
                # Trap and handle any errors
                try:
                    # Get the data from the API
                    response = session.get(url, timeout=30)
                    # Handle ESI throttling
                    if response.status_code in (420, 429):
                        # Use Retry-After if available
                        retry_after = response.headers.get("Retry-After")
                        # If there was a retry-after
                        if retry_after is not None:
                            delay = int(retry_after)
                        else:
                            # Exponential backoff
                            delay = min(2 ** attempt, 30)
                        # Alert the user
                        print(
                            f"\n[WARN] "
                            f"ESI throttle {response.status_code} "
                            f"for {type_id} "
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
                    # Build our output Dict
                    out[int(type_id)] = {
                        "ID": int(type_id),
                        "Type": data["name"],
                    }
                    # Success
                    break
                # Error handling
                except requests.RequestException as e:
                    # Final failure
                    if attempt == max_retries - 1:
                        # Generate a runtime error
                        raise RuntimeError(
                            f"Failed system {type_id}"
                        ) from e
                    # Exponential retry backoff
                    delay = min(2 ** attempt, 30)
                    # Warn the user
                    print(
                        f"\n[WARN] "
                        f"Request failure for {type_id} "
                        f"(attempt {attempt + 1}/{max_retries}) "
                        f"sleeping {delay}s"
                    )
                    # Wait for a bit for things to stabilize
                    sleep(delay)
        # Send the final results back to the caller
        return out
    # ---------------------------------------------------------
    # Execute
    #
    # Here we cannot use invoke_url_batch_processor, basically because
    # we need a periodic save to ensure that if something happens during
    # the update, we will only need to restart from approximately where
    # the failure occurred. The Types data is large and the API is slow,
    # a restart mechanism can be useful to save time.
    # ---------------------------------------------------------
    # Fast FIFO queue
    q = deque(MissingTypes)
    # Preserve original workload size
    total = len(q)
    # Retry tracking
    retries = {}
    # Completion tracking
    completed = 0
    # Autosave tracking
    new_records = 0
    save_threshold = 500
    # Limits for the size and number of batches we can process at one time
    batch_size = 100
    max_jobs = 10
    # Retries
    max_retries = 5
    # Efficient batch builder
    def make_batch():
        size = min(batch_size, len(q))
        return [q.popleft() for _ in range(size)]
    # Create a thread pool with as many threads as we need to handle the maximum number of jobs we are going to run
    with ThreadPoolExecutor(max_workers=max_jobs) as pool:
        # Create a Dict with the job as the key and batch as the value to enable restarts, preserving the original batch
        futures = {}
        # Fill the worker pool with jobs
        while q and len(futures) < max_jobs:
            # Create the bach if type ids we want to process
            batch = make_batch()
            # Add the job to the pool, updating the dict with the new job and its batch
            futures[pool.submit(type_job, batch, api, source)] = batch
        # Keep processing while there are jobs in the pool
        while futures:
            # Wait for at least one completion
            done, _ = wait(futures,return_when=FIRST_COMPLETED)
            # Process completed jobs
            for future in done:
                # Retrieve the batch value and remove the job from the futures dict
                batch = futures.pop(future)
                try:
                    # Retrieve the dict result from the completed job
                    out = future.result()
                    # Merge the returned dictionary with our master dictionary
                    if out:
                        # Count only genuinely new records
                        added = 0
                        # Iterate through all the returned items, obtaining the key and values
                        for k, v in out.items():
                            # If the key doesn't already exist in our Types Dict then increment our counter
                            if k not in Types:
                                added += 1
                            # Add or update the record in the Types Dict
                            Types[k] = v
                        # Update the progress bar stats
                        completed += len(out)
                        # Update the periodic save stats
                        new_records += added
                        # Autosave every 500 new records
                        if new_records >= save_threshold:
                            # Output the API data to the CSV 
                            save_toCSV(thisfile, Types)
                            # Reset the periodic save stats
                            new_records = 0
                # Handle any errors
                except Exception:
                    # Create an immutable identifier representing this batch so it can be tracked in dictionaries or sets.
                    key = tuple(batch)
                    # Increase the retry count for this key by 1. If the key does not exist yet, start it at 0 first.
                    retries[key] = retries.get(key, 0) + 1
                    # Retry if allowed
                    if retries[key] <= max_retries:
                        # Warn the user
                        print(
                            f"\n[WARN] Retrying batch "
                            f"({retries[key]}/{max_retries}): "
                            f"{batch}"
                        )
                        # Wait a bit for things to stabilize
                        sleep(0.2)
                        # Restart the job with its original batch and add it to the futures Dict
                        futures[pool.submit(type_job,batch,api,source,)] = batch
                    # If we have no more retries
                    else:
                        # warn the user
                        print(
                            f"\n[ERROR] "
                            f"Batch permanently failed: {batch}"
                        )
                # Refill the worker slot immediately if there are items still left in the queue
                if q:
                    # Create a new batch
                    new_batch = make_batch()
                    # Submit the new job, adding it to the futures Dict with its batch as a value
                    futures[pool.submit(type_job,new_batch,api,source,)] = new_batch
            # Update the percentages for our rpogress bar
            pct = (
                min(100, int((completed / total) * 100))
                if total
                else 100
            )
            # Output the progress bar, overwriting the previous bar data
            print(
                f"\r{"Processing missing Types"} | "
                f"Completed: {completed}/{total} | "
                f"Running: {len(futures)} | "
                f"{pct}%",
                end="",
                flush=True,
            )
    # Final save if pending changes remain
    if new_records > 0:
        # Output the API data to the CSV 
        save_toCSV(thisfile, Types)
    # Output a newline to preserve the progress bar
    print("")
"""

Get the Stations list.

Stations are quite dynamic in Eve Online. We will re-use
the existing CSV data, or create it from the market data
if we need to.

This data is updated as station ids listed in the market data
are found to be missing. Incremental updates save a lot of time.
"""
# Create a master dict to hold our stations data
stations = {}
# Set the full path to the expected CSV file
thisfile = datafolder + "Stations.csv"
if Path(thisfile).exists():
    # Announce the action
    print("Querying Stations from CSV...")
     # Read the csv data
    stations = get_FromCSV(thisfile, "ID")
else:
    # Announce the action
    print("Creating Stations CSV file...")
    # Create the CSV 
    with open(thisfile, 'w', encoding="utf-8", newline='') as f:
        # Write the header line
        f.write("\"ID\",\"Name\",\"SystemID\"\n")
"""
Get the WatchMarkets list.

Querying all the orders in all the markets in Eve takes a very long time.
To reduce the orders data down to chunks we can work with in Excel, we filter
the orders down to specific markets.

"""
# Set the full path to the expected CSV file
thisfile = datafolder + "WatchMarkets.csv"
# If the file exists, read it
if Path(thisfile).exists():
    # Announce the action
    print("Querying WatchMarkets from CSV...")
    # Read the csv data
    # Because we cannot expect the ID value to be present, we cannot use the
    # get_FromCSV function with the ID column as the index key.
    watchmarkets = get_FromCSV(thisfile, None)
    # Correct missing data
    for key in watchmarkets.keys():
        # If the Station ID is missing, add it from the Stations data
        if watchmarkets[key]['ID'] == "":
            # Iterate through the Stations data to find the matching Station Name and add the ID
            for stationkey in stations.keys():
                # If the names match, add the ID to the WatchMarkets data
                if stations[stationkey]['Name'] == watchmarkets[key]['StationName']:
                    watchmarkets[key]['ID'] = stations[stationkey]['ID']
                    print(f"Added missing Station ID {stations[stationkey]['ID']} for WatchMarket {watchmarkets[key]['StationName']}")
        # If the ID is still missing, check if the name matches a Structure, and add the ID if it does
        if watchmarkets[key]['ID'] == "":
            # Iterate through the Structures data to find the matching Structure Name and add the ID
            for structurekey in structures.keys():
                # If the names match, add the ID to the WatchMarkets data
                if structures[structurekey]['Name'] == watchmarkets[key]['StationName']:
                    watchmarkets[key]['ID'] = structures[structurekey]['ID']
                    print(f"Added missing Structure ID {structures[structurekey]['ID']} for WatchMarket {watchmarkets[key]['StationName']}")   
        # If the Region ID is missing, add it from the Regions data
        if watchmarkets[key]['RegionID'] == "":
            # Iterate through the Regions data to find the matching Region Name and add the ID
            for regionkey in regions.keys():
                # If the names match, add the ID to the WatchMarkets data
                if regions[regionkey]['Region'] == watchmarkets[key]['RegionName']:
                    watchmarkets[key]['RegionID'] = regions[regionkey]['ID']
                    print(f"Added missing Region ID {regions[regionkey]['ID']} for WatchMarket {watchmarkets[key]['RegionName']}")
else:
    # Announce the action
    print("Creating WatchMarkets CSV file...")
    # Create the CSV 
    with open(thisfile, 'w', encoding="utf-8", newline='') as f:
        # Write the header line
        f.write("\"ID\",\"Name\",\"StationName\",\"RegionName\",\"RegionID\"\n")
"""
Get the WatchItems list.

Querying all the orders in all the markets in Eve takes a very long time.
To reduce the orders data down to chunks we can work with in Excel, we filter
the orders down to specific products.

"""
# Set the full path to the expected CSV
thisfile = datafolder + "WatchItems.csv"
# If the file exists, load it
if Path(thisfile).exists():
    # Announce the action
    print("Querying WatchItems from CSV...")
    # Read the csv data
    # Because we cannot expect the ID value to be present, we cannot use the
    # get_FromCSV function with the ID column as the index key.     
    watchitems = get_FromCSV(thisfile, None)
    # Correct missing data
    for key in watchitems.keys():
        # If the Type ID is missing, add it from the Types data
        if watchitems[key]['ItemID'] == "":
            # Iterate through the Types data to find the matching Type Name and add the ID
            for typekey in Types.keys():
                # If the names match, add the ID to the WatchItems data
                if Types[typekey]['Type'] == watchitems[key]['ItemName']:
                    watchitems[key]['ItemID'] = Types[typekey]['ID']
                    print(f"Added missing Type ID {Types[typekey]['ID']} for WatchItem {watchitems[key]['ItemName']}")
"""
Get the Orders list.

Querying all the orders in all the markets in Eve takes a very long time.

This routines queries all the buy and sell orders for the regional markets
specified in our Markets watchlist.

"""
# Track the regions we have already reported orders for, so we can skip any duplicate orders
# for the same region that may be listed in multiple watch markets.
ReportedRegions = []
# Create the master Orders dictionary to hold the orders data
orders = {}
# Create a list to hold missing stations
MissingStations =  []
# ---------------------------------------------------------
# Worker
# ---------------------------------------------------------
def order_job(batch, api, source, RegionID):
    # Create a persistent session that we can re-use to save on reconnection times
    session = requests.Session()
    # Initialize our Dict to hold the results
    out = {}
    # Process each page in the batch for the specified RegionID
    for id in batch:
        # Form the URL
        url = (
            f"https://esi.evetech.net/"
            f"{api}/markets/"
            f"{RegionID}/orders/"
            f"?datasource={source}&order_type=all"
            f"&page={id}"
        )
        # Retry up to 5 times if we have to
        max_retries = 5
        # Keep attempting until we succeed or run out of retries
        for attempt in range(max_retries):
            # Trap and handle any errors
            try:
                # Get the data from the API
                response = session.get(url, timeout=30)
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
                        f"for Region {RegionID} "
                        f"page {id} "
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
                orders = response.json()
                # Iterate through all the orders in the page data
                for order in orders:
                    # Get the order id
                    order_id = int(order["order_id"])
                    # Build our output Dict
                    out[order_id] = {
                        "StationID": int(order["location_id"]),
                        "TypeID": int(order["type_id"]),
                        "IsBuy": bool(order["is_buy_order"]),
                        "Price": float(order["price"]),
                        "Remaining": int(order["volume_remain"]),
                        "Total": int(order["volume_total"]),
                        "OrderID": order_id,
                    }
                # Success
                break
            # Error handling
            except requests.RequestException as e:
                # Final failure
                if attempt == max_retries - 1:
                    # Generate a runtime error
                    raise RuntimeError(
                        f"Failed region {RegionID} "
                        f"page {id}"
                    ) from e
                # Exponential retry backoff
                delay = min(2 ** attempt, 30)
                # Warn the user
                print(
                    f"\n[WARN] "
                    f"Request failure for Region {RegionID} "
                    f"page {id} "
                    f"(attempt {attempt + 1}/{max_retries}) "
                    f"sleeping {delay}s"
                )
                # Wait for a bit for things to stabilize
                sleep(delay)
    # Send the final results back to the caller
    return out
# ---------------------------------------------------------
# Execute
# ---------------------------------------------------------
# Build an index dict for our WatchItems
WatchItemIDs = {}
for key in watchitems.keys():
    WatchItemIDs[watchitems[key]['ItemID']] = key
# Build an Index dict for our WatchMarkets
WatchMarketIDs = {}
for key in watchmarkets.keys():
    WatchMarketIDs[watchmarkets[key]['ID']] = key
#
# Iterate through the WatchMarkets list
for key in watchmarkets.keys():
    # Get the Region ID for this market
    regionid = watchmarkets[key]['RegionID']
    regionname = watchmarkets[key]['RegionName']
    # If we have already reported orders for this region, skip to the next market
    if regionid in ReportedRegions:
        continue
    # Add the regionid to ReportedRegions
    ReportedRegions.append(regionid)
    # Get the list of orders for this region from REST API
    url = "https://esi.evetech.net/" + api + "/markets/" + str(regionid) + "/orders/?datasource=" + source + "&page=1"
    # Make the request to the API
    response =  requests.get(url, headers=myheader, timeout=(10, 20))    
    # Get the MaxPages reported back in the header of the response
    maxpages = int(response.headers.get('X-Pages', 1))
    # ---------------------------------------------------------
    # Execute
    #
    # We can't use invoke_url_batch_processor for this batch because we have to also
    # pass the RegionID as well to the worker thread.
    # ---------------------------------------------------------
    # Build the queue of page numbers
    q = deque(list(range(1, maxpages + 1)))
    # Activity for the progress bar
    activity="Loading orders for " + regionname
    # Limit the maximum jobs and items in each batch
    max_jobs=4
    batch_size=100
    # Preserve original workload size
    total = maxpages
    # Final output (master) dictionary
    results = {}
    # Retry tracking
    retries = {}
    # Completion tracking
    completed = 0
    # Efficient batch builder
    def make_batch():
        size = min(batch_size, len(q))
        return [q.popleft() for _ in range(size)]
    # Create a thread pool with enough workers to handle the maximum jobs we want to run
    with ThreadPoolExecutor(max_workers=max_jobs) as pool:
        # This Dict allows us to map batches to a job for later retrieval in the retry logic
        futures = {}
        # Fill the pool with workers from the queue
        while q and len(futures) < max_jobs:
            # Populate the batch with the page ID's we want to process
            batch = make_batch()
            # Add the job to the pool and update the futures Dict, adding the job as the key and batch as the value
            futures[pool.submit(order_job, batch, api, source, regionid)] = batch
        # Keep processing while we have running jobs
        while futures:
            # Wait for at least one completion
            done, _ = wait(futures,return_when=FIRST_COMPLETED)
            # Process completed jobs
            for future in done:
                # Retrieve the batch data and remove the job from the futures Dict
                batch = futures.pop(future)
                try:
                    # Retrieve the result from the completed job
                    out = future.result()
                    # Merge the returned dictionary with our master dictionary
                    if out:
                        # Add the returned data to the results (master) Dict
                        results.update(out)
                        # Update the progress bar stats
                        completed += len(batch)
                # handle any errors
                except Exception:
                    # Create an immutable identifier representing this batch so it can be tracked in dictionaries or sets.
                    key = tuple(batch)
                    # Increase the retry count for this key by 1. If the key does not exist yet, start it at 0 first.
                    retries[key] = retries.get(key, 0) + 1
                    # Retry if allowed
                    if retries[key] <= max_retries:
                        # Warn the user
                        print(
                            f"\n[WARN] Retrying batch "
                            f"({retries[key]}/{max_retries}): "
                            f"{batch}"
                        )
                        # Wait a bit for things to stabilize
                        sleep(0.2)
                        # Restart the job and update the futures Dict
                        futures[pool.submit(order_job,batch,api,source,regionid)] = batch
                    # If retries are exhausted
                    else:
                        # Warn the user
                        print(
                            f"\n[ERROR] "
                            f"Batch permanently failed: {batch}"
                        )
                # Refill the worker slot immediately
                if q:
                    # Create the batch of page IDs to rpocess
                    new_batch = make_batch()
                    # Add the job to the pool and update the futures Dict
                    futures[pool.submit(order_job,new_batch,api,source,regionid)] = new_batch
            # Update the progress percentage calculation for the bar
            pct = (
                min(100, int((completed / total) * 100))
                if total
                else 100
            )
            # Update the progress bar, overwriting the previous output
            print(
                f"\r{activity} | "
                f"Completed: {completed}/{total} pages | "
                f"Running: {len(futures)} | "
                f"{pct}%",
                end="",
                flush=True,
            )
    # ----------------------------------------------------------
    # Post Process Orders
    #
    # In order to make the Prices calculations easier, we use a customized
    # structure of nested Dicts.
    # ----------------------------------------------------------
    for r in results:
        order = results[r]
        TypeID = order["TypeID"]
        StationID = order["StationID"]
        # Is this an item we are watching?
        if TypeID in WatchItemIDs:
            # Is this a market we are watching?
            if StationID in WatchMarketIDs:
                # Create the Orders data Dict using the TypeID as key if it doesn't exist
                if TypeID not in orders.keys():
                    orders[TypeID] = {}
                # Now create the Orders Type Dict for the station if it doesn't exist
                if StationID not in orders[TypeID].keys():
                    orders[TypeID][StationID] = {}
                    orders[TypeID][StationID]["Buy"] = {}
                    orders[TypeID][StationID]["Sell"] = {}
                # Add the order to the Orders data
                OrderID = order["OrderID"]
                IsBuy = order["IsBuy"]
                Price = order["Price"]
                Remaining = order["Remaining"]
                Total = order["Total"]
                if IsBuy:
                    orders[TypeID][StationID]["Buy"][OrderID] = {"Price": Price, "Remaining": Remaining, "Total": Total}
                else:
                    orders[TypeID][StationID]["Sell"][OrderID] = {"Price": Price, "Remaining": Remaining, "Total": Total}
        # If stations doesn't have this stationid, add it to MissingStations
        if ((StationID < 1000000000000) and (StationID not in stations) and (StationID not in MissingStations)):
            MissingStations.append(StationID)
    print("")
"""
Save the Orders list.

This routine saves the Orders data to a CSV file. Because of the complexity of the Orders data structure, 
we save it in a flattened format with one line per order, and columns for the TypeID, StationID,
Type (Buy/Sell), Price, Total Volume and Remaining Volume.

"""
thisfile = datafolder + "Orders.csv"
# Announce the action
print("Saving Orders data to CSV...")
# Create the CSV
with open(thisfile, 'w', encoding="utf-8", newline='') as f:
    # Write the header line
    f.write("\"TypeID\",\"StationID\",\"Type\",\"OrderID\",\"Price\",\"Total\",\"Remaining\"\n")
    # Iterate through the Orders data and write each order to the CSV
    for TypeID in orders.keys():
        for StationID in orders[TypeID].keys():
            for OrderType in ["Buy", "Sell"]:
                for OrderID in orders[TypeID][StationID][OrderType].keys():
                    Price = orders[TypeID][StationID][OrderType][OrderID]['Price']
                    Total = orders[TypeID][StationID][OrderType][OrderID]['Total']
                    Remaining = orders[TypeID][StationID][OrderType][OrderID]['Remaining']
                    # Write the line to the CSV
                    f.write(f"{TypeID},{StationID},\"{OrderType}\",{OrderID},{Price},{Total},{Remaining}\n")
# ----------------------------------------------------------
# Process missing stations
#
# There is no ESI endpoint to get station details in bulk, so we have to query each station individually. To do 
# this efficiently, we can build a list of missing stations from the market data since all stations have a market.
# Once we know which stations we are missing, we can use a batched approach with multiple threads to query the station
# details in parallel. We will implement retries and throttling handling in the same way as we do for orders to ensure
# that we can get as much data as possible even if there are transient issues with the API. Finally, we will save the
# station details to our Stations hash and persist it to the CSV file.
# ----------------------------------------------------------
# Announce the result
print(f"Found {len(MissingStations)} missing stations.")
# Only collect the data if we have found missing stations
if (len(MissingStations) > 0):
    # ---------------------------------------------------------
    # Worker
    # ---------------------------------------------------------
    def station_job(batch, api, source):
        # Create a persistent session that we can re-use to save on reconnection times
        session = requests.Session()
        # Initialize our Dict to hold the results
        out = {}
        # Process each station id in the batch
        for station_id in batch:
            # Form the URL
            url = (
                f"https://esi.evetech.net/"
                f"{api}/universe/stations/"
                f"{station_id}/"
                f"?datasource={source}&language=en"
            )
            # Retry up to 5 times if we have to
            max_retries = 5
            # Keep attempting until we succeed or run out of retries
            for attempt in range(max_retries):
                # Trap and handle any errors
                try:
                    # Get the data from the API
                    response = session.get(url, timeout=30)
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
                            f"for {station_id} "
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
                    # Build our output Dict
                    out[int(station_id)] = {
                        "ID": int(station_id),
                        "Name": data["name"],
                        "SystemID": int(data["system_id"])
                    }
                    # Success
                    break
                # Error handling
                except requests.RequestException as e:
                    # Final failure
                    if attempt == max_retries - 1:
                        # Generate a runtime error
                        raise RuntimeError(
                            f"Failed system {station_id}"
                        ) from e
                    # Exponential retry backoff
                    delay = min(2 ** attempt, 30)
                    # Warn the user
                    print(
                        f"\n[WARN] "
                        f"Request failure for {station_id} "
                        f"(attempt {attempt + 1}/{max_retries}) "
                        f"sleeping {delay}s"
                    )
                    # Wait for a bit for things to stabilize
                    sleep(delay)
        # Send the final results back to the caller
        return out
    # ---------------------------------------------------------
    # Execute
    # ---------------------------------------------------------
    # Invoke the batch processor
    results = invoke_url_batch_processor(
        queue=MissingStations,
        job_block=station_job,
        activity="Loading Stations",
        max_jobs=5,
        batch_size=40,
        api=api,
        source=source,
    )
    # Output a newline to preserve the progress bar
    print("")
    # Combine the results with the stations data
    for r in results:
        # Add the station data to the master Dict
        stations[r] = results[r]
    # Save to CSV
    thisfile = datafolder + "Stations.csv"
    save_toCSV(thisfile, stations)
"""
Save the other changed data.

This routine saves the Stations, Types, WatchItems and WatchMarkets data to CSV files.

"""
# Announce the action
print("Saving changed WatchItems and WatchMarkets data to CSV...")
# Re-export the WatchItems data to the CSV to capture any added Type IDs
thisfile = datafolder + "WatchItems.csv"
save_toCSV(thisfile, watchitems)
# Re-export the WatchMarkets data to the CSV to capture any added Station IDs
thisfile = datafolder + "WatchMarkets.csv"
save_toCSV(thisfile, watchmarkets)
"""
Calculate the Low, High and Average prices per item and transaction type per station.

This Price data is what we feed into the Excel sheet to do the profit calculations, 
so we want to calculate it here in the script and just feed the final price data into Excel.

"""
# Announce the action
print("Calculating summary prices data...")
# Create the Prices dictionary to hold the price summary data
pricedata = {}
# Iterate through the Orders data to calculate the Low, High and Average prices for each item, station and order type
for TypeID in orders.keys():
    # If we don't yet have price data for the type, add it
    if TypeID not in pricedata:
        pricedata[TypeID] = {}
    # Iterate through all the stations with data for this type
    for StationID in orders[TypeID].keys():
        # If we don't yet have price data for this station, add it
        if StationID not in pricedata[TypeID]:
            pricedata[TypeID][StationID] = {}
        # Now iterate through the order types
        for OrderType in ["Buy", "Sell"]:
            # Get all the orders for this type, station and order type
            order_set = orders[TypeID][StationID].get(OrderType,{})
            # Skip empty order groups entirely
            if not order_set:
                continue
            # Create output structure ONLY if data exists
            if OrderType not in pricedata[TypeID][StationID]:
                pricedata[TypeID][StationID][OrderType] = {}
            # Initialize our stats
            high = 0
            low = float(999999999999)
            totalprice = 0.0
            totalremaining = 0
            # Iterate through all order for this type, station, order type
            for OrderID, order in order_set.items():
                # Store these for ease of use
                Price = float(order['Price'])
                Remaining = int(order['Remaining'])
                # Calculate the high price
                if Price > high:
                    high = Price
                # Calculate the low price
                if Price < low:
                    low = Price
                # Calculate the cumulcative values we need for the averages
                totalprice += Price * Remaining
                totalremaining += Remaining
            # Now that all the orders have been processed, calculate the average price
            average = (
                totalprice / totalremaining
                if totalremaining > 0
                else 0
            )
            # Populate the summary stats
            pricedata[TypeID][StationID][OrderType]['High'] = high
            pricedata[TypeID][StationID][OrderType]['Low'] = low
            pricedata[TypeID][StationID][OrderType]['Average'] = average
"""
Save the Prices Dict data

This routine saves the Prices data to a CSV file. Because of the complexity of the Prices data structure, 
we save it in a flattened format with one line per item/station/order type, and columns for
the TypeID, StationID, Order Type (Buy/Sell), High Price, Low Price and Average Price.

"""
# Announce the action
print("Saving summary prices data...")
# Create the CSV
thisfile = datafolder + "Prices.csv"
with open(thisfile, 'w', encoding="utf-8", newline='') as f:
    # Write the header line
    f.write("\"TypeID\",\"StationID\",\"OrderType\",\"High\",\"Low\",\"Average\"\n")
    # Iterate through the Prices data and write each line to the CSV
    for TypeID in pricedata.keys():
        for StationID in pricedata[TypeID].keys():
            for OrderType in pricedata[TypeID][StationID].keys():
                High = pricedata[TypeID][StationID][OrderType]['High']
                Low = pricedata[TypeID][StationID][OrderType]['Low']
                Average = pricedata[TypeID][StationID][OrderType]['Average']
                f.write(f"{TypeID},{StationID},\"{OrderType}\",{High},{Low},{Average}\n")
# Announce the end of the process
endtime = datetime.now()
elapsedMinutes = (endtime - starttime).total_seconds() / 60
print("Process completed:", endtime.strftime("%Y-%m-%d %H:%M:%S"), " Minutes: ",  str(elapsedMinutes))
#
# Uncomment for testing
input("Press Enter to exit...")