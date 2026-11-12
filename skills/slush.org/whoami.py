#!/usr/bin/env python3
"""Sign in to the Slush platform and name the account: identity is its user_id."""

import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import slush_client as sc  # noqa: E402

argparse.ArgumentParser(description=__doc__).parse_args()
sc.login()
u = sc.user
sc.emit_ok({"name": f'{u.get("first_name", "")} {u.get("last_name", "")}'.strip(),
            "email": u.get("email"), "title": u.get("title")})
