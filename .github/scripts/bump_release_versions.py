# ------------------------------------------------------------------------
#
# Copyright 2026 WSO2, LLC. (http://wso2.com)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License
#
# ------------------------------------------------------------------------
"""Raise docker_release_version values in the image build pipeline's product data file.

Usage: bump_release_versions.py <file> <product_version>=<docker_release_version> ...

Only the profile whose docker_repo_name is $DOCKER_REPO_NAME (default "wso2-is/is") is edited.
Lines are changed in place so the file's formatting is kept. A version is never lowered, and
product versions missing from the file are skipped. Prints "<product> <old> -> <new>" per change.
"""
import json
import os
import re
import sys


def version_key(version):
    return tuple(int(part) for part in version.split("."))


def find_profile(data, repo_name):
    for profile in data.get("profiles", []):
        if profile.get("docker_repo_name") == repo_name:
            return profile
    return None


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path, pairs = sys.argv[1], sys.argv[2:]
    repo_name = os.environ.get("DOCKER_REPO_NAME", "wso2-is/is")

    with open(path, encoding="utf-8") as f:
        text = f.read()
    profile = find_profile(json.loads(text), repo_name)
    if profile is None:
        sys.exit(f"profile {repo_name} not found")
    current = {v["product_version"]: v["docker_release_version"] for v in profile.get("versions", [])}

    # Restrict edits to this profile's block of the file.
    start_match = re.search(r'"docker_repo_name"\s*:\s*"%s"' % re.escape(repo_name), text)
    if start_match is None:
        sys.exit(f"profile {repo_name} not found in text")
    start = start_match.end()
    next_profile = re.search(r'"docker_repo_name"\s*:', text[start:])
    end = start + next_profile.start() if next_profile else len(text)
    block = text[start:end]

    expected = {}
    for pair in pairs:
        product, _, release = pair.partition("=")
        old = current.get(product)
        if old is None or version_key(release) <= version_key(old):
            continue
        pattern = re.compile(
            r'("product_version"\s*:\s*"%s"\s*,\s*"docker_release_version"\s*:\s*")%s(")'
            % (re.escape(product), re.escape(old)))
        block, count = pattern.subn(lambda m: m.group(1) + release + m.group(2), block)
        if count != 1:
            sys.exit(f"could not update {product}: expected 1 match, found {count}")
        expected[product] = release
        print(f"{product} {old} -> {release}")

    if not expected:
        return
    text = text[:start] + block + text[end:]

    # Make sure the result is valid JSON and holds exactly the intended values.
    updated = find_profile(json.loads(text), repo_name)
    for version in updated["versions"]:
        want = expected.get(version["product_version"], current[version["product_version"]])
        if version["docker_release_version"] != want:
            sys.exit(f"verification failed for {version['product_version']}")

    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


if __name__ == "__main__":
    main()
