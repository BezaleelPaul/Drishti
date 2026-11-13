import os
import sys

_PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_TOOLBOX_PATH = os.path.join(_PROJECT_ROOT, "external", "fundus_image_toolbox")
if os.path.exists(_TOOLBOX_PATH) and _TOOLBOX_PATH not in sys.path:
    sys.path.insert(0, _TOOLBOX_PATH)

__version__ = "1.1.0"
