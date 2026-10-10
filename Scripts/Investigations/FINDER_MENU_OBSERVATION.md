# Finder 冷菜单采集与状态判断

`NativeMenuGeometry.swift` 只读取指定标题和几何范围的前台 Finder 调查窗口；需要同时编译 `OwnedFinderWindow.swift`。输出中的两种加载提示与当前 `FinderMenuPresentation.UnavailableState` 保持一致，由 `test_finder_menu_observation.py` 检查。

```sh
mkdir -p .build/Temporary/menu-observation
xcrun swiftc -parse-as-library Scripts/Investigations/OwnedFinderWindow.swift Scripts/Investigations/NativeMenuGeometry.swift -o .build/Temporary/menu-observation/native-menu-geometry
```

采集器的参数为调查窗口标题、X、Y、Width、Height，标题必须以 `QuickFileNativePerf-` 开头。运行需要辅助功能授权，窗口身份不匹配时拒绝采集。不要将读到的其他窗口当作本次样本。

Python 驱动通过 `finder-menu-state.py` 的 `submenu_requires_reopen(rows, creation_title)` 判断采集结果：可见创建项返回 `False`，可见加载提示返回 `True`，无可见目标或未知状态返回 `None`。`None` 不能当作已准备或必需重开；驱动应继续有界观测，超时则明确报告样本无效。

本模块只解决加载状态漏测，不证明冷菜单延迟、后台准备完成时间或 P95。输入、关闭/重开、准备、文件出现及显示选中仍需要同一次实机时间线。使用后按 CONTRIBUTING.md 回收临时二进制和夹具。
