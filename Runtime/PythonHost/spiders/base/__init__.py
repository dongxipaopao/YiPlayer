# base/__init__.py — marks `base` as a package so that
# `from base.spider import Spider` resolves inside the app bundle.
# (pd.py does sys.path.append('..') and imports base.spider; the
# bundle's spiders/ directory is on sys.path, so `base` is found here.)
