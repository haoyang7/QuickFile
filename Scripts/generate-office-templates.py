#!/usr/bin/env python3
"""Generate embedded, blank OOXML documents using only the Python standard library.

Run from any directory; use --check to verify the checked-in Swift data. Package
parts use OOXML Transitional namespaces, fixed ZIP metadata, and sorted entries.
No document properties, macros, external relationships, or preview images exist.

Package structure references:
https://learn.microsoft.com/en-us/office/open-xml/spreadsheet/working-with-sheets
https://learn.microsoft.com/en-us/office/open-xml/presentation/structure-of-a-presentationml-document
"""

from __future__ import annotations

import argparse
import base64
from io import BytesIO
from pathlib import Path
from textwrap import dedent, wrap
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Shared/OfficeDocumentData.swift"
REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PACKAGE_REL = "http://schemas.openxmlformats.org/package/2006/relationships"
CONTENT_TYPES = "http://schemas.openxmlformats.org/package/2006/content-types"
WORD = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
SHEET = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
PRESENTATION = "http://schemas.openxmlformats.org/presentationml/2006/main"
DRAWING = "http://schemas.openxmlformats.org/drawingml/2006/main"
MIME = "application/vnd.openxmlformats-officedocument."
ZIP_TIME = (1980, 1, 1, 0, 0, 0)


def xml(body: str) -> bytes:
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            + dedent(body).strip() + "\n").encode("utf-8")


def relationships(*entries: tuple[str, str, str]) -> bytes:
    children = "".join(
        f'<Relationship Id="{identifier}" Type="{REL}/{kind}" Target="{target}"/>'
        for identifier, kind, target in entries
    )
    return xml(f'<Relationships xmlns="{PACKAGE_REL}">{children}</Relationships>')


def package(parts: dict[str, bytes], types: dict[str, str], main: str) -> bytes:
    parts = dict(parts)
    overrides = "".join(
        f'<Override PartName="/{name}" ContentType="{MIME}{kind}"/>'
        for name, kind in sorted(types.items())
    )
    parts["[Content_Types].xml"] = xml(f"""
        <Types xmlns="{CONTENT_TYPES}">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          {overrides}
        </Types>
    """)
    parts["_rels/.rels"] = relationships(("rId1", "officeDocument", main))
    output = BytesIO()
    with ZipFile(output, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
        for name, content in sorted(parts.items()):
            info = ZipInfo(name, date_time=ZIP_TIME)
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = ZIP_DEFLATED
            archive.writestr(info, content, compresslevel=9)
    return output.getvalue()


def word_document() -> bytes:
    return package({
        "word/document.xml": xml(f"""
            <w:document xmlns:w="{WORD}">
              <w:body>
                <w:p/>
                <w:sectPr>
                  <w:pgSz w:w="11906" w:h="16838"/>
                  <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>
                </w:sectPr>
              </w:body>
            </w:document>
        """),
        "word/styles.xml": xml(f"""
            <w:styles xmlns:w="{WORD}">
              <w:docDefaults>
                <w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/></w:rPr></w:rPrDefault>
                <w:pPrDefault/>
              </w:docDefaults>
              <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
            </w:styles>
        """),
        "word/_rels/document.xml.rels": relationships(("rId1", "styles", "styles.xml")),
    }, {
        "word/document.xml": "wordprocessingml.document.main+xml",
        "word/styles.xml": "wordprocessingml.styles+xml",
    }, "word/document.xml")


def spreadsheet() -> bytes:
    return package({
        "xl/workbook.xml": xml(f"""
            <workbook xmlns="{SHEET}" xmlns:r="{REL}">
              <bookViews><workbookView activeTab="0"/></bookViews>
              <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
            </workbook>
        """),
        "xl/worksheets/sheet1.xml": xml(f"""
            <worksheet xmlns="{SHEET}">
              <dimension ref="A1"/>
              <sheetViews><sheetView workbookViewId="0"><selection activeCell="A1" sqref="A1"/></sheetView></sheetViews>
              <sheetFormatPr defaultRowHeight="15"/>
              <sheetData/>
              <pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>
            </worksheet>
        """),
        "xl/styles.xml": xml(f"""
            <styleSheet xmlns="{SHEET}">
              <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>
              <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
              <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
              <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
              <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>
              <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
            </styleSheet>
        """),
        "xl/_rels/workbook.xml.rels": relationships(
            ("rId1", "worksheet", "worksheets/sheet1.xml"),
            ("rId2", "styles", "styles.xml"),
        ),
    }, {
        "xl/workbook.xml": "spreadsheetml.sheet.main+xml",
        "xl/worksheets/sheet1.xml": "spreadsheetml.worksheet+xml",
        "xl/styles.xml": "spreadsheetml.styles+xml",
    }, "xl/workbook.xml")


def theme() -> bytes:
    colors = {
        "dk1": "000000", "lt1": "FFFFFF", "dk2": "333333", "lt2": "F2F2F2",
        "accent1": "4472C4", "accent2": "ED7D31", "accent3": "A5A5A5",
        "accent4": "FFC000", "accent5": "5B9BD5", "accent6": "70AD47",
        "hlink": "0563C1", "folHlink": "954F72",
    }
    color_scheme = "".join(
        f'<a:{name}><a:srgbClr val="{value}"/></a:{name}>'
        for name, value in colors.items()
    )
    solid_fill = '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
    line = f'<a:ln w="9525">{solid_fill}<a:prstDash val="solid"/></a:ln>'
    # DrawingML requires three entries in each format style list.
    return xml(f"""
        <a:theme xmlns:a="{DRAWING}" name="QuickFile">
          <a:themeElements>
            <a:clrScheme name="QuickFile">{color_scheme}</a:clrScheme>
            <a:fontScheme name="QuickFile">
              <a:majorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>
              <a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>
            </a:fontScheme>
            <a:fmtScheme name="QuickFile">
              <a:fillStyleLst>{solid_fill * 3}</a:fillStyleLst>
              <a:lnStyleLst>{line * 3}</a:lnStyleLst>
              <a:effectStyleLst>{'<a:effectStyle><a:effectLst/></a:effectStyle>' * 3}</a:effectStyleLst>
              <a:bgFillStyleLst>{solid_fill * 3}</a:bgFillStyleLst>
            </a:fmtScheme>
          </a:themeElements>
          <a:objectDefaults/><a:extraClrSchemeLst/>
        </a:theme>
    """)


def presentation() -> bytes:
    namespaces = f'xmlns:p="{PRESENTATION}" xmlns:a="{DRAWING}" xmlns:r="{REL}"'
    shape_tree = """
        <p:spTree>
          <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
          <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        </p:spTree>
    """
    text_style = '<a:lvl1pPr><a:defRPr sz="1800"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/></a:defRPr></a:lvl1pPr>'
    parts = {
        "ppt/presentation.xml": xml(f"""
            <p:presentation {namespaces}>
              <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
              <p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst>
              <p:sldSz cx="12192000" cy="6858000" type="screen16x9"/>
              <p:notesSz cx="6858000" cy="9144000"/>
              <p:defaultTextStyle>{text_style}</p:defaultTextStyle>
            </p:presentation>
        """),
        "ppt/presProps.xml": xml(f'<p:presentationPr {namespaces}/>'),
        "ppt/slides/slide1.xml": xml(f"""
            <p:sld {namespaces}>
              <p:cSld>{shape_tree}</p:cSld>
              <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
            </p:sld>
        """),
        "ppt/slideLayouts/slideLayout1.xml": xml(f"""
            <p:sldLayout {namespaces} type="blank" preserve="1">
              <p:cSld name="Blank">{shape_tree}</p:cSld>
              <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
            </p:sldLayout>
        """),
        "ppt/slideMasters/slideMaster1.xml": xml(f"""
            <p:sldMaster {namespaces}>
              <p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>{shape_tree}</p:cSld>
              <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
              <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
              <p:txStyles><p:titleStyle>{text_style}</p:titleStyle><p:bodyStyle>{text_style}</p:bodyStyle><p:otherStyle>{text_style}</p:otherStyle></p:txStyles>
            </p:sldMaster>
        """),
        "ppt/theme/theme1.xml": theme(),
        "ppt/_rels/presentation.xml.rels": relationships(
            ("rId1", "slideMaster", "slideMasters/slideMaster1.xml"),
            ("rId2", "slide", "slides/slide1.xml"),
            ("rId3", "theme", "theme/theme1.xml"),
            ("rId4", "presProps", "presProps.xml"),
        ),
        "ppt/slides/_rels/slide1.xml.rels": relationships(("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")),
        "ppt/slideLayouts/_rels/slideLayout1.xml.rels": relationships(("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")),
        "ppt/slideMasters/_rels/slideMaster1.xml.rels": relationships(
            ("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"),
            ("rId2", "theme", "../theme/theme1.xml"),
        ),
    }
    types = {
        "ppt/presentation.xml": "presentationml.presentation.main+xml",
        "ppt/presProps.xml": "presentationml.presProps+xml",
        "ppt/slides/slide1.xml": "presentationml.slide+xml",
        "ppt/slideLayouts/slideLayout1.xml": "presentationml.slideLayout+xml",
        "ppt/slideMasters/slideMaster1.xml": "presentationml.slideMaster+xml",
        "ppt/theme/theme1.xml": "theme+xml",
    }
    return package(parts, types, "ppt/presentation.xml")


def documents() -> dict[str, bytes]:
    return {"docx": word_document(), "xlsx": spreadsheet(), "pptx": presentation()}


def swift_source() -> str:
    lines = [
        "// Generated by Scripts/generate-office-templates.py; edit the generator to change these documents.",
        "import Foundation", "", "// Static constants initialize on first access, with no file or compression dependency.",
        "enum OfficeDocumentData {",
    ]
    for extension, content in documents().items():
        lines.append(f'    static let {extension}: Data = Data(base64Encoded: """')
        lines.extend("        " + line for line in wrap(base64.b64encode(content).decode("ascii"), 100))
        lines.append('        """, options: .ignoreUnknownCharacters)!')
    lines.extend(["}", ""])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify Swift data without writing")
    parser.add_argument("--output", type=Path, default=OUTPUT, help="generated Swift destination")
    arguments = parser.parse_args()
    expected = swift_source()
    if arguments.check:
        if not arguments.output.is_file() or arguments.output.read_text() != expected:
            parser.exit(1, "Office document data differs; run Scripts/generate-office-templates.py.\n")
    else:
        arguments.output.write_text(expected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
