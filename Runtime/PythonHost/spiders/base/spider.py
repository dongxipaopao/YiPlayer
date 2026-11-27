# base/spider.py — minimal CatVod `base.spider` compatibility package.
#
# pd.py starts with:
#     sys.path.append('..')
#     from base.spider import Spider as BaseSpider
# (with a local fallback if the import fails). This package provides
# that import, implementing ONLY what pd.py actually uses — read from
# pd.py (522 lines, dongpian17.com spider), not guessed from other
# spiders:
#   * Spider.__init__ / init(extend) / getName()
#   * isVideoFormat / manualVideoCheck / destroy / localProxy
#     (pd.py overrides all five; the base versions only need to exist
#     so `super().init(...)` and the fallback chain do not crash)
#   * fetch(url, ...) — defined in pd.py's own fallback BaseSpider and
#     used by other CatVod spiders; pd.py itself never calls it, but
#     any spider imported here may, so it is provided via requests.
#   * self.extend — pd.py's init() reads getattr(self, 'extend', '').
#
# Nothing else is implemented on purpose. A spider that needs lxml,
# bs4, pyquery, pycryptodome or a real browser must say so in its
# error, not silently get a half-working base class. The full list of
# what this package does NOT provide is in BUILD_NOTES.md.
import requests


class Spider(object):
    """CatVod base spider: the smallest surface pd.py depends on."""

    def __init__(self):
        self.extend = ''

    def init(self, extend=""):
        self.extend = extend if isinstance(extend, str) else ''

    def getName(self):
        return ""

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return False

    def destroy(self):
        pass

    def localProxy(self, param):
        return None

    def fetch(self, url, params=None, headers=None, cookies=None,
              timeout=15, verify=False, encoding="utf-8", **kwargs):
        resp = requests.get(url, params=params, headers=headers,
                            cookies=cookies, timeout=timeout,
                            verify=verify, **kwargs)
        resp.encoding = encoding
        return resp
