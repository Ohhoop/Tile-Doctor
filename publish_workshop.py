"""Publishes the Workshop item described by workshop.vdf, next to this script, through the Steamworks API of the running Steam client.

Usage:
    python publish_workshop.py [--skip-content] [--skip-descriptions] [--skip-tags] [--dry-run]

The Steam client must be running and logged on, and Project Zomboid closed: the script speaks to Steam as the game.

Steps, each one running even when a previous one failed:
    1. A new item is created when workshop.vdf has no published id yet, and its id is written back into workshop.vdf.
    2. Content, preview, title, visibility and change note in one update. When Steam refuses the preview, the update is sent
       again without it.
    3. The tags of the mod's workshop.txt, then one localized description per file of the descriptions folder.
"""

import argparse
import ctypes
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
VDF_PATH = os.path.join(HERE, "workshop.vdf")
DESCRIPTIONS_DIR = os.path.join(HERE, "descriptions")

STEAM_API_DLL = os.environ.get("STEAM_API_DLL", r"H:\1 - Jeux\Steam\steamapps\common\ProjectZomboid\steam_api64.dll")

CREATE_ITEM_RESULT_CALLBACK = 3403
CREATE_ITEM_RESULT_SIZE = 24
SUBMIT_ITEM_UPDATE_RESULT_CALLBACK = 3404
SUBMIT_ITEM_UPDATE_RESULT_SIZE = 16
WORKSHOP_FILE_TYPE_COMMUNITY = 0
RESULT_OK = 1
CALL_TIMEOUT_SECONDS = 120
CONTENT_TIMEOUT_SECONDS = 1800
LOGON_TIMEOUT_SECONDS = 30
DESCRIPTION_MAX_BYTES = 7999

LANGUAGE_CODES = {
    "EN": "english", "CN": "schinese", "CH": "tchinese", "JP": "japanese", "KO": "koreana",
    "TH": "thai", "ID": "indonesian", "MS": "malay", "BG": "bulgarian", "CS": "czech",
    "DA": "danish", "DE": "german", "ES": "spanish", "LATAM": "latam", "EL": "greek",
    "FR": "french", "IT": "italian", "HU": "hungarian", "NL": "dutch", "NO": "norwegian",
    "PL": "polish", "PT": "portuguese", "PTBR": "brazilian", "RO": "romanian", "RU": "russian",
    "FI": "finnish", "SV": "swedish", "TR": "turkish", "VI": "vietnamese", "UA": "ukrainian",
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


def absolute_path(value):
    """Returns a path of workshop.vdf made absolute, relative to this script."""
    if os.path.isabs(value):
        return os.path.normpath(value)
    return os.path.normpath(os.path.join(HERE, value))


def record_published_id(pairs, published_id):
    """Writes the published id into workshop.vdf, keeping every other entry as it is."""
    write_vdf(VDF_PATH, [(key, str(published_id) if key == "publishedfileid" else value) for key, value in pairs])


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


def read_tags(content_folder):
    """Returns the tags listed on the tags line of the workshop.txt next to the content folder, or None when there is no such line."""
    path = os.path.join(HERE, os.path.dirname(content_folder.rstrip("/\\")), "workshop.txt")
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("tags="):
                return [tag.strip() for tag in line[len("tags="):].split(";") if tag.strip()]
    return None


def usable_descriptions():
    """Returns the descriptions that can be sent and a report line for each one that cannot."""
    reports, usable = [], []
    descriptions = read_descriptions()
    if not descriptions:
        reports.append("descriptions: none found")
    for code, language, text in descriptions:
        size = len(text.encode("utf-8"))
        if language is None:
            reports.append("description {}: SKIPPED (unknown language code)".format(code))
        elif size > DESCRIPTION_MAX_BYTES:
            reports.append("description {}: SKIPPED ({} bytes, limit {})".format(code, size, DESCRIPTION_MAX_BYTES))
        else:
            usable.append((code, language, text))
    return reports, usable


def result_line(label, result):
    """Returns the report line of a Steam call: OK, or FAILED with the Steam result code."""
    return "{}: {}".format(label, "OK" if result == RESULT_OK else "FAILED (Steam result {})".format(result))


class SteamParamStringArray(ctypes.Structure):
    """Mirrors the Steamworks SteamParamStringArray_t structure holding a list of strings."""
    _fields_ = [("strings", ctypes.POINTER(ctypes.c_char_p)), ("count", ctypes.c_int32)]


class SteamWorkshop:
    """Creates and updates Workshop items through the Steamworks API of the running Steam client."""

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
        self._wait_for_logon()

    def _wait_for_logon(self):
        """Pumps the Steam callbacks until the client reports the user as logged on, or raises when it takes too long."""
        user = self.api.SteamAPI_SteamUser_v023()
        deadline = time.time() + LOGON_TIMEOUT_SECONDS
        while not self.api.SteamAPI_ISteamUser_BLoggedOn(user):
            if time.time() > deadline:
                raise RuntimeError("the Steam client did not report the user as logged on")
            self.api.SteamAPI_RunCallbacks()
            time.sleep(0.2)

    def _declare(self):
        """Declares the argument and return types of the Steam API functions used."""
        api = self.api
        handle_and_text = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
        api.SteamAPI_InitFlat.argtypes = [ctypes.c_char_p]
        api.SteamAPI_InitFlat.restype = ctypes.c_int
        api.SteamAPI_SteamUGC_v021.restype = ctypes.c_void_p
        api.SteamAPI_SteamUtils_v010.restype = ctypes.c_void_p
        api.SteamAPI_ISteamUGC_CreateItem.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int]
        api.SteamAPI_ISteamUGC_CreateItem.restype = ctypes.c_uint64
        api.SteamAPI_ISteamUGC_StartItemUpdate.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint64]
        api.SteamAPI_ISteamUGC_StartItemUpdate.restype = ctypes.c_uint64
        for name in ("SetItemTitle", "SetItemContent", "SetItemPreview", "SetItemUpdateLanguage", "SetItemDescription"):
            function = getattr(api, "SteamAPI_ISteamUGC_" + name)
            function.argtypes = handle_and_text
            function.restype = ctypes.c_bool
        api.SteamAPI_ISteamUGC_SetItemVisibility.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_int]
        api.SteamAPI_ISteamUGC_SetItemVisibility.restype = ctypes.c_bool
        api.SteamAPI_ISteamUGC_SetItemTags.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(SteamParamStringArray), ctypes.c_bool]
        api.SteamAPI_ISteamUGC_SetItemTags.restype = ctypes.c_bool
        api.SteamAPI_ISteamUGC_SubmitItemUpdate.argtypes = handle_and_text
        api.SteamAPI_ISteamUGC_SubmitItemUpdate.restype = ctypes.c_uint64
        api.SteamAPI_ISteamUtils_IsAPICallCompleted.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_bool)]
        api.SteamAPI_ISteamUtils_IsAPICallCompleted.restype = ctypes.c_bool
        api.SteamAPI_ISteamUtils_GetAPICallResult.argtypes = [
            ctypes.c_void_p, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_bool)]
        api.SteamAPI_ISteamUtils_GetAPICallResult.restype = ctypes.c_bool
        api.SteamAPI_SteamUser_v023.restype = ctypes.c_void_p
        api.SteamAPI_ISteamUser_BLoggedOn.argtypes = [ctypes.c_void_p]
        api.SteamAPI_ISteamUser_BLoggedOn.restype = ctypes.c_bool
        api.SteamAPI_RunCallbacks.restype = None
        api.SteamAPI_Shutdown.restype = None

    def _wait_for_call(self, call, callback, size, timeout):
        """Waits for a Steam call and returns the bytes of its result structure, or None on timeout or failure."""
        failed = ctypes.c_bool(False)
        deadline = time.time() + timeout
        while not self.api.SteamAPI_ISteamUtils_IsAPICallCompleted(self.utils, call, ctypes.byref(failed)):
            if time.time() > deadline:
                return None
            self.api.SteamAPI_RunCallbacks()
            time.sleep(0.2)
        buffer = ctypes.create_string_buffer(size)
        if not self.api.SteamAPI_ISteamUtils_GetAPICallResult(self.utils, call, buffer, len(buffer), callback, ctypes.byref(failed)) or failed.value:
            return None
        return buffer.raw

    def _submit(self, handle, change_note, timeout=CALL_TIMEOUT_SECONDS):
        """Submits an item update with its change note and returns the Steam result code, or None when it could not be submitted."""
        call = self.api.SteamAPI_ISteamUGC_SubmitItemUpdate(self.ugc, handle, change_note.encode("utf-8"))
        raw = self._wait_for_call(call, SUBMIT_ITEM_UPDATE_RESULT_CALLBACK, SUBMIT_ITEM_UPDATE_RESULT_SIZE, timeout)
        if raw is None:
            return None
        return int.from_bytes(raw[0:4], "little", signed=True)

    def create_item(self):
        """Creates a new community item for the app; returns the Steam result code and the published id, 0 when none was made."""
        call = self.api.SteamAPI_ISteamUGC_CreateItem(self.ugc, self.app_id, WORKSHOP_FILE_TYPE_COMMUNITY)
        raw = self._wait_for_call(call, CREATE_ITEM_RESULT_CALLBACK, CREATE_ITEM_RESULT_SIZE, CALL_TIMEOUT_SECONDS)
        if raw is None:
            return None, 0
        return int.from_bytes(raw[0:4], "little", signed=True), int.from_bytes(raw[8:16], "little")

    def update_content(self, published_id, content, preview, title, visibility, change_note):
        """Submits the content folder, the preview file when given, the title and the visibility in one update; returns the Steam result code, or None when it could not be submitted."""
        handle = self.api.SteamAPI_ISteamUGC_StartItemUpdate(self.ugc, self.app_id, published_id)
        if not self.api.SteamAPI_ISteamUGC_SetItemContent(self.ugc, handle, content.encode("utf-8")):
            return None
        if preview and not self.api.SteamAPI_ISteamUGC_SetItemPreview(self.ugc, handle, preview.encode("utf-8")):
            return None
        if title and not self.api.SteamAPI_ISteamUGC_SetItemTitle(self.ugc, handle, title.encode("utf-8")):
            return None
        if visibility is not None and not self.api.SteamAPI_ISteamUGC_SetItemVisibility(self.ugc, handle, visibility):
            return None
        return self._submit(handle, change_note, CONTENT_TIMEOUT_SECONDS)

    def set_description(self, published_id, language, text, change_note):
        """Submits the description of the item for the Steam language; returns the Steam result code, or None when it could not be submitted."""
        handle = self.api.SteamAPI_ISteamUGC_StartItemUpdate(self.ugc, self.app_id, published_id)
        if not self.api.SteamAPI_ISteamUGC_SetItemUpdateLanguage(self.ugc, handle, language.encode("utf-8")):
            return None
        if not self.api.SteamAPI_ISteamUGC_SetItemDescription(self.ugc, handle, text.encode("utf-8")):
            return None
        return self._submit(handle, change_note)

    def set_tags(self, published_id, tags, change_note):
        """Submits the tags of the item, replacing the current ones; returns the Steam result code, or None when they could not be submitted."""
        encoded = [tag.encode("utf-8") for tag in tags]
        strings = (ctypes.c_char_p * len(encoded))(*encoded)
        array = SteamParamStringArray(strings, len(encoded))
        handle = self.api.SteamAPI_ISteamUGC_StartItemUpdate(self.ugc, self.app_id, published_id)
        if not self.api.SteamAPI_ISteamUGC_SetItemTags(self.ugc, handle, ctypes.byref(array), False):
            return None
        return self._submit(handle, change_note)

    def close(self):
        """Disconnects from the Steam client."""
        self.api.SteamAPI_Shutdown()


def publish_content(workshop, published_id, values, change_note):
    """Uploads the content with its preview, then again without the preview when Steam refuses it; returns a report line."""
    content = absolute_path(values["contentfolder"])
    preview = absolute_path(values["previewfile"]) if values.get("previewfile") else None
    title = values.get("title")
    visibility = int(values["visibility"]) if values.get("visibility") else None
    result = workshop.update_content(published_id, content, preview, title, visibility, change_note)
    if result == RESULT_OK:
        return "content and preview: OK"
    if preview is None:
        return result_line("content", result)
    retry = workshop.update_content(published_id, content, None, title, visibility, change_note)
    if retry == RESULT_OK:
        return "content: OK, preview: FAILED (Steam result {}, update sent again without it)".format(result)
    return "content and preview: FAILED (Steam result {}, then {} without the preview)".format(result, retry)


def dry_run_report(values, published_id, send_content, tags, descriptions):
    """Returns the report of what a run would send, without contacting Steam."""
    report = []
    if published_id == 0:
        report.append("item: would be created")
    if send_content:
        preview = absolute_path(values["previewfile"]) if values.get("previewfile") else "no preview"
        report.append("content: would send {} with {}".format(absolute_path(values["contentfolder"]), preview))
    if tags is not None:
        report.append("tags: would be set to {}".format(";".join(tags)))
    for code, language, text in descriptions or []:
        report.append("description {} ({}): would be sent, {} bytes".format(code, language, len(text.encode("utf-8"))))
    return report


def main():
    """Runs the requested publishing steps through the Steam client and prints a report of each one."""
    parser = argparse.ArgumentParser(description="Publishes the Workshop item of workshop.vdf through the running Steam client.")
    parser.add_argument("--skip-content", action="store_true", help="do not upload the content and preview")
    parser.add_argument("--skip-descriptions", action="store_true", help="do not upload the localized descriptions")
    parser.add_argument("--skip-tags", action="store_true", help="do not upload the tags of the mod's workshop.txt")
    parser.add_argument("--dry-run", action="store_true", help="show what would be sent without contacting Steam")
    args = parser.parse_args()

    pairs = read_vdf(VDF_PATH)
    values = dict(pairs)
    app_id = int(values["appid"])
    published_id = int(values["publishedfileid"])
    change_note = values.get("changenote", "")
    tags = None if args.skip_tags else read_tags(values.get("contentfolder", ""))
    report, descriptions = [], None
    if not args.skip_descriptions:
        report, descriptions = usable_descriptions()

    if args.dry_run:
        print("\n".join(["", "==== Report ===="] + report + dry_run_report(values, published_id, not args.skip_content, tags, descriptions)))
        return 0

    try:
        workshop = SteamWorkshop(app_id)
    except (OSError, RuntimeError) as error:
        print("\n".join(["", "==== Report ====", "Steam client: FAILED ({})".format(error)]))
        return 1
    try:
        if published_id == 0:
            result, new_id = workshop.create_item()
            report.append(result_line("item creation", result))
            if result == RESULT_OK and new_id:
                published_id = new_id
                record_published_id(pairs, published_id)
                report.append("published id {} recorded in workshop.vdf".format(published_id))
        if published_id == 0:
            report.append("content, tags and descriptions: SKIPPED (no published id)")
        else:
            if not args.skip_content:
                report.append(publish_content(workshop, published_id, values, change_note))
            if tags is not None:
                report.append(result_line("tags " + ";".join(tags), workshop.set_tags(published_id, tags, change_note)))
            for code, language, text in descriptions or []:
                report.append(result_line("description {} ({})".format(code, language), workshop.set_description(published_id, language, text, change_note)))
    finally:
        workshop.close()

    print("\n".join(["", "==== Report ===="] + report))
    return 0 if not any("FAILED" in line for line in report) else 1


if __name__ == "__main__":
    sys.exit(main())
