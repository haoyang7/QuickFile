"""Classify an observed submenu; missing or hidden rows are not readiness proof."""

LOADING_TITLES = frozenset({"正在确认创建位置…", "正在加载模板…"})


def submenu_requires_reopen(rows, creation_title):
    visible = {row["title"] for row in rows if row["width"] > 0 and row["height"] > 0}
    if creation_title in visible:
        return False
    if visible & LOADING_TITLES:
        return True
    return None
