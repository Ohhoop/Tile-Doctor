"""Publishes the Workshop item described by workshop.vdf, next to this script.

Usage:
    python publish_workshop.py [--skip-content] [--skip-descriptions] [--dry-run]

Steps, each one running even when a previous one failed:
    1. Content, preview and change note through SteamCMD. When Steam refuses the
       preview, the upload is retried without it.
    2. One localized description per file of the descriptions folder, through
       the Steamworks API of the running Steam client.
"""

import argparse
import ctypes
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
VDF_PATH = os.path.join(HERE, "workshop.vdf")
DESCRIPTIONS_DIR = os.path.join(HERE, "descriptions")

STEAMCMD = os.environ.get("STEAMCMD", r"D:\2 - Projet Perso\Mods PZ\steamcmd\steamcmd.exe")
STEAM_USER = os.environ.get("STEAM_USER", "ohhoop")
STEAM_API_DLL = os.environ.get("STEAM_API_DLL", r"H:\1 - Jeux\Steam\steamapps\common\ProjectZomboid\steam_api64.dll")

PATH_KEYS = ("contentfolder", "previewfile")
SUBMIT_ITEM_UPDATE_RESULT_CALLBACK = 3404
RESULT_OK = 1
CALL_TIMEOUT_SECONDS = 120
DESCRIPTION_MAX_BYTES = 7999

LANGUAGE_CODES = {
    "EN": "english", "FR": "french", "DE": "german", "ES": "spanish", "ES_MX": "latam",
    "ES_CL": "latam", "AR": "latam", "PT": "portuguese", "PTBR": "brazilian", "IT": "italian",
    "NL": "dutch", "DA": "danish", "FI": "finnish", "NO": "norwegian", "PL": "polish",
    "CS": "czech", "HU": "hungarian", "RO": "romanian", "RU": "russian", "UA": "ukrainian",
    "TR": "turkish", "TH": "thai", "ID": "indonesian", "JP": "japanese", "KO": "koreana",
    "CN": "schinese", "CH": "tchinese",
}


def read_vdf(path):
    """Returns the key and value pairs of a flat workshopitem vdf file, in file order."""
    with open(path, encoding="utf-8") as handle:
        return re.findall(r'"([^"]+)"\s+"((?:[^"\\]|\\.)*)"', handle.read())


def write_vdf(path, pairs):
    """Writes the key and value pairs as a workshopitem vdf file."""
    lines = ['"workshopitem"', "{"]
    lines += ['\t"{}"\t\t"{}"'.format(key, value) for key, value in pairs]
    lines.append("}")
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(lines) + "\n")


def absolute_pairs(pairs):
    """Returns the pairs with the content and preview paths made absolute, relative to this script."""
    result = []
    for key, value in pairs:
        if key in PATH_KEYS and not os.path.isabs(value):
            value = os.path.normpath(os.path.join(HERE, value)).replace("\\", "\\\\")
        result.append((key, value))
    return result


def run_steamcmd(pairs, dry_run):
    """Uploads a temporary vdf built from the pairs with SteamCMD; returns whether Steam reported success, and the output."""
    handle, vdf = tempfile.mkstemp(suffix=".vdf")
    os.close(handle)
    try:
        write_vdf(vdf, pairs)
        if dry_run:
            with open(vdf, encoding="utf-8") as generated:
                return True, generated.read()
        command = [STEAMCMD, "+login", STEAM_USER, "+workshop_build_item", vdf, "+quit"]
        completed = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace")
        output = completed.stdout + completed.stderr
        failed = completed.returncode != 0 or re.search(r"ERROR|Failed|failure", output, re.IGNORECASE)
        return not failed, output
    finally:
        os.remove(vdf)


def publish_content(pairs, dry_run):
    """Uploads the content with its preview, then again without the preview when Steam refuses it; returns a report line."""
    ok, output = run_steamcmd(pairs, dry_run)
    if ok:
        return "content and preview: OK", output
    if not any(key == "previewfile" for key, _ in pairs):
        return "content: FAILED", output
    without_preview = [(key, value) for key, value in pairs if key != "previewfile"]
    retry_ok, retry_output = run_steamcmd(without_preview, dry_run)
    if retry_ok:
        return "content: OK, preview: FAILED (upload retried without it)", output + retry_output
    return "content and preview: FAILED", output + retry_output


def read_descriptions():
    """Returns the Steam language code and the text of every description file, the English one first."""
    if not os.path.isdir(DESCRIPTIONS_DIR):
        return []
    found = []
    for name in sorted(os.listdir(DESCRIPTIONS_DIR)):
        stem, extension = os.path.splitext(name)
        if extension.lower() != ".txt":
            continue
        with open(os.path.join(DESCRIPTIONS_DIR, name), encoding="utf-8") as handle:
            found.append((stem.upper(), LANGUAGE_CODES.get(stem.upper()), handle.read().strip()))
    found.sort(key=lambda entry: entry[0] != "EN")
    return found


class SteamWorkshop:
    """Updates localized Workshop descriptions through the Steamworks API of the running Steam client."""

    def __init__(self, app_id):
        """Loads the Steam API library and connects to the running Steam client as the given app."""
        os.environ["SteamAppId"] = str(app_id)
        os.environ["SteamGameId"] = str(app_id)
        self.app_id = app_id
        self.api = ctypes.CDLL(STEAM_API_DLL)
        self._declare()
        error = ctypes.create_string_buffer(1024)
        if self.api.SteamAPI_InitFlat(error) != 0:
            raise RuntimeError("Steam API could not start: " + error.value.decode("utf-8", "replace"))
        self.ugc = self.api.SteamAPI_SteamUGC_v021()
        self.utils = self.api.SteamAPI_SteamUtils_v010()

    def _declare(self):
        """Declares the argument and return types of the Steam API functions used."""
        api = self.api
        api.SteamAPI_InitFlat.argtypes = [ctypes.c_char_p]
        api.SteamAPI_InitFlat.restype = ctypes.c_int
        api.SteamAPI_SteamUGC_v021.restype = ctypes.c_void_p
        api.SteamAPI_SteamUtils_v010.restype = ctypes.c_void_p
        api.SteamAPI_ISteamUGC_StartItemUpdate.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint64]
        api.SteamAPI_ISteamUGC_StartItemUpdate.restype = ctypes.c_uint64
        api.SteamAPI_ISteamUGC_SetItemUpdateLanguage.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
        api.SteamAPI_ISteamUGC_SetItemUpdateLanguage.restype = ctypes.c_bool
        api.SteamAPI_ISteamUGC_SetItemDescription.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
        api.SteamAPI_ISteamUGC_SetItemDescription.restype = ctypes.c_bool
        api.SteamAPI_ISteamUGC_SubmitItemUpdate.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
        api.SteamAPI_ISteamUGC_SubmitItemUpdate.restype = ctypes.c_uint64
        api.SteamAPI_ISteamUtils_IsAPICallCompleted.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_bool)]
        api.SteamAPI_ISteamUtils_IsAPICallCompleted.restype = ctypes.c_bool
        api.SteamAPI_ISteamUtils_GetAPICallResult.argtypes = [
            ctypes.c_void_p, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_bool)]
        api.SteamAPI_ISteamUtils_GetAPICallResult.restype = ctypes.c_bool
        api.SteamAPI_RunCallbacks.restype = None
        api.SteamAPI_Shutdown.restype = None

    def _wait_for_result(self, call):
        """Waits for the submitted update and returns its Steam result code, or None on timeout or failure."""
        failed = ctypes.c_bool(False)
        deadline = time.time() + CALL_TIMEOUT_SECONDS
        while not self.api.SteamAPI_ISteamUtils_IsAPICallCompleted(self.utils, call, ctypes.byref(failed)):
            if time.time() > deadline:
                return None
            self.api.SteamAPI_RunCallbacks()
            time.sleep(0.2)
        buffer = ctypes.create_string_buffer(32)
        if not self.api.SteamAPI_ISteamUtils_GetAPICallResult(
                self.utils, call, buffer, len(buffer), SUBMIT_ITEM_UPDATE_RESULT_CALLBACK, ctypes.byref(failed)) or failed.value:
            return None
        return int.from_bytes(buffer.raw[0:4], "little", signed=True)

    def set_description(self, published_id, language, text, change_note):
        """Submits the description of the item for the Steam language; returns the Steam result code, or None when it could not be submitted."""
        handle = self.api.SteamAPI_ISteamUGC_StartItemUpdate(self.ugc, self.app_id, published_id)
        if not self.api.SteamAPI_ISteamUGC_SetItemUpdateLanguage(self.ugc, handle, language.encode("utf-8")):
            return None
        if not self.api.SteamAPI_ISteamUGC_SetItemDescription(self.ugc, handle, text.encode("utf-8")):
            return None
        call = self.api.SteamAPI_ISteamUGC_SubmitItemUpdate(self.ugc, handle, change_note.encode("utf-8"))
        return self._wait_for_result(call)

    def close(self):
        """Disconnects from the Steam client."""
        self.api.SteamAPI_Shutdown()


def publish_descriptions(app_id, published_id, change_note, dry_run):
    """Submits every description file as its localized description; returns one report line per language."""
    descriptions = read_descriptions()
    if not descriptions:
        return ["descriptions: none found"]
    reports = []
    usable = []
    for code, language, text in descriptions:
        if language is None:
            reports.append("description {}: SKIPPED (unknown language code)".format(code))
        elif len(text.encode("utf-8")) > DESCRIPTION_MAX_BYTES:
            reports.append("description {}: SKIPPED ({} bytes, limit {})".format(code, len(text.encode("utf-8")), DESCRIPTION_MAX_BYTES))
        else:
            usable.append((code, language, text))
    if dry_run:
        return reports + ["description {} ({}): would be sent, {} bytes".format(c, l, len(t.encode("utf-8"))) for c, l, t in usable]
    try:
        workshop = SteamWorkshop(app_id)
    except (OSError, RuntimeError) as error:
        return reports + ["descriptions: FAILED ({})".format(error)]
    try:
        for code, language, text in usable:
            result = workshop.set_description(published_id, language, text, change_note)
            status = "OK" if result == RESULT_OK else "FAILED (Steam result {})".format(result)
            reports.append("description {} ({}): {}".format(code, language, status))
    finally:
        workshop.close()
    return reports


def main():
    """Runs the requested publishing steps and prints a report of each one."""
    parser = argparse.ArgumentParser(description="Publishes the Workshop item of workshop.vdf.")
    parser.add_argument("--skip-content", action="store_true", help="do not upload the content and preview")
    parser.add_argument("--skip-descriptions", action="store_true", help="do not upload the localized descriptions")
    parser.add_argument("--dry-run", action="store_true", help="show what would be sent without contacting Steam")
    args = parser.parse_args()

    pairs = read_vdf(VDF_PATH)
    values = dict(pairs)
    app_id = int(values["appid"])
    published_id = int(values["publishedfileid"])
    change_note = values.get("changenote", "")

    report = []
    if not args.skip_content:
        line, output = publish_content(absolute_pairs(pairs), args.dry_run)
        print(output)
        report.append(line)
    if not args.skip_descriptions:
        if published_id == 0:
            report.append("descriptions: SKIPPED (the item has no published id yet; set publishedfileid first)")
        else:
            report.extend(publish_descriptions(app_id, published_id, change_note, args.dry_run))

    print("\n".join(["", "==== Report ===="] + report))
    return 0 if not any("FAILED" in line for line in report) else 1


if __name__ == "__main__":
    sys.exit(main())
