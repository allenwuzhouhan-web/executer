#!/usr/bin/env python3
"""
PPT Design Language Extractor
Extracts the complete design system from a .pptx file:
  - Slide dimensions & layout structure
  - Color palette (every color used, with frequency)
  - Typography system (fonts, sizes, weights, line spacing)
  - Element positioning grid (where things are placed)
  - Shape catalog (types, sizes, fill patterns)
  - Text hierarchy (title vs subtitle vs body patterns)
  - Image placement patterns
  - Slide-by-slide structural blueprint

Usage:
    python ppt_design_extractor.py input.pptx
    python ppt_design_extractor.py input.pptx -o design_language.json
    python ppt_design_extractor.py input.pptx --format markdown
"""

import argparse
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

try:
    from pptx import Presentation
    from pptx.util import Inches, Pt, Emu
    from pptx.enum.text import PP_ALIGN
    from pptx.enum.shapes import MSO_SHAPE_TYPE
    from pptx.dml.color import RGBColor
except ImportError:
    print("Install python-pptx first:")
    print("  pip install python-pptx")
    sys.exit(1)


def emu_to_inches(emu):
    """Convert EMU to inches, rounded to 2 decimal places."""
    if emu is None:
        return None
    return round(emu / 914400, 2)


def emu_to_pt(emu):
    """Convert EMU to points."""
    if emu is None:
        return None
    return round(emu / 12700, 1)


def extract_color(color_obj):
    """Safely extract color as hex string."""
    try:
        if color_obj is None:
            return None
        if hasattr(color_obj, 'rgb') and color_obj.rgb is not None:
            return f"#{color_obj.rgb}"
        if hasattr(color_obj, 'theme_color') and color_obj.theme_color is not None:
            return f"theme:{color_obj.theme_color}"
    except Exception:
        pass
    return None


def extract_fill(shape):
    """Extract fill information from a shape."""
    try:
        fill = shape.fill
        if fill is None:
            return None
        fill_type = str(fill.type) if fill.type is not None else None
        result = {"type": fill_type}
        if fill.type is not None:
            ft = str(fill.type)
            if "SOLID" in ft:
                try:
                    result["color"] = extract_color(fill.fore_color)
                except Exception:
                    pass
            elif "GRADIENT" in ft:
                stops = []
                try:
                    for stop in fill.gradient_stops:
                        stops.append({
                            "position": round(stop.position, 2),
                            "color": extract_color(stop.color)
                        })
                except Exception:
                    pass
                result["gradient_stops"] = stops
        return result
    except Exception:
        return None


def extract_text_formatting(paragraph):
    """Extract detailed text formatting from a paragraph."""
    runs_info = []
    for run in paragraph.runs:
        run_data = {"text": run.text}
        font = run.font
        if font.name:
            run_data["font"] = font.name
        if font.size:
            run_data["size_pt"] = emu_to_pt(font.size)
        if font.bold:
            run_data["bold"] = True
        if font.italic:
            run_data["italic"] = True
        if font.underline:
            run_data["underline"] = True
        color = extract_color(font.color)
        if color:
            run_data["color"] = color
        runs_info.append(run_data)

    para_data = {}
    if paragraph.alignment is not None:
        align_map = {
            PP_ALIGN.LEFT: "left",
            PP_ALIGN.CENTER: "center",
            PP_ALIGN.RIGHT: "right",
            PP_ALIGN.JUSTIFY: "justify",
        }
        para_data["alignment"] = align_map.get(paragraph.alignment, str(paragraph.alignment))

    pf = paragraph.paragraph_format
    if pf.space_before is not None:
        para_data["space_before_pt"] = emu_to_pt(pf.space_before)
    if pf.space_after is not None:
        para_data["space_after_pt"] = emu_to_pt(pf.space_after)
    if pf.line_spacing is not None:
        para_data["line_spacing"] = round(pf.line_spacing, 2) if isinstance(pf.line_spacing, float) else emu_to_pt(pf.line_spacing)
    if pf.level is not None and pf.level > 0:
        para_data["indent_level"] = pf.level

    if runs_info:
        para_data["runs"] = runs_info

    return para_data


def extract_shape_info(shape, slide_width, slide_height):
    """Extract complete information from a shape."""
    info = {
        "name": shape.name,
        "shape_type": str(shape.shape_type) if shape.shape_type else None,
    }

    # Position & size in inches + as percentage of slide
    if shape.left is not None:
        info["position"] = {
            "left_in": emu_to_inches(shape.left),
            "top_in": emu_to_inches(shape.top),
            "width_in": emu_to_inches(shape.width),
            "height_in": emu_to_inches(shape.height),
            "left_pct": round(shape.left / slide_width * 100, 1) if slide_width else None,
            "top_pct": round(shape.top / slide_height * 100, 1) if slide_height else None,
            "width_pct": round(shape.width / slide_width * 100, 1) if slide_width else None,
            "height_pct": round(shape.height / slide_height * 100, 1) if slide_height else None,
        }

    # Rotation
    if hasattr(shape, 'rotation') and shape.rotation:
        info["rotation_deg"] = shape.rotation

    # Fill
    fill = extract_fill(shape)
    if fill:
        info["fill"] = fill

    # Line/border
    try:
        line = shape.line
        if line and line.fill and line.fill.type is not None:
            line_info = {}
            if line.width:
                line_info["width_pt"] = emu_to_pt(line.width)
            line_color = extract_color(line.color)
            if line_color:
                line_info["color"] = line_color
            if line.dash_style:
                line_info["dash"] = str(line.dash_style)
            if line_info:
                info["border"] = line_info
    except Exception:
        pass

    # Shadow
    try:
        if hasattr(shape, 'shadow') and shape.shadow:
            shadow = shape.shadow
            if shadow.inherit is False:
                info["has_shadow"] = True
    except Exception:
        pass

    # Text content
    if shape.has_text_frame:
        tf = shape.text_frame
        info["text_frame"] = {
            "word_wrap": tf.word_wrap,
        }
        # Margins
        margins = {}
        if tf.margin_left is not None:
            margins["left_in"] = emu_to_inches(tf.margin_left)
        if tf.margin_right is not None:
            margins["right_in"] = emu_to_inches(tf.margin_right)
        if tf.margin_top is not None:
            margins["top_in"] = emu_to_inches(tf.margin_top)
        if tf.margin_bottom is not None:
            margins["bottom_in"] = emu_to_inches(tf.margin_bottom)
        if margins:
            info["text_frame"]["margins"] = margins

        # Paragraphs
        paragraphs = []
        for para in tf.paragraphs:
            pdata = extract_text_formatting(para)
            if pdata:
                paragraphs.append(pdata)
        if paragraphs:
            info["text_frame"]["paragraphs"] = paragraphs

    # Table
    if shape.has_table:
        table = shape.table
        info["table"] = {
            "rows": len(table.rows),
            "cols": len(table.columns),
            "col_widths_in": [emu_to_inches(col.width) for col in table.columns],
            "row_heights_in": [emu_to_inches(row.height) for row in table.rows],
        }
        # Extract first row as header sample
        if len(table.rows) > 0:
            header_cells = []
            for cell in table.rows[0].cells:
                cell_data = {"text": cell.text}
                if cell.fill and cell.fill.type is not None:
                    cell_data["fill"] = extract_fill(cell)
                header_cells.append(cell_data)
            info["table"]["header_sample"] = header_cells

    # Chart
    if shape.has_chart:
        chart = shape.chart
        info["chart"] = {
            "chart_type": str(chart.chart_type),
            "has_legend": chart.has_legend,
            "series_count": len(chart.series) if chart.series else 0,
        }

    # Image / Picture
    if shape.shape_type == MSO_SHAPE_TYPE.PICTURE:
        try:
            img = shape.image
            info["image"] = {
                "content_type": img.content_type,
                "width_px": img.size[0] if hasattr(img, 'size') else None,
                "height_px": img.size[1] if hasattr(img, 'size') else None,
            }
        except Exception:
            info["image"] = {"note": "embedded image"}

    # Group
    if shape.shape_type == MSO_SHAPE_TYPE.GROUP:
        info["group_children"] = len(shape.shapes)

    # Placeholder info
    if shape.is_placeholder:
        ph = shape.placeholder_format
        info["placeholder"] = {
            "idx": ph.idx,
            "type": str(ph.type),
        }

    return info


def extract_slide_layout_info(layout):
    """Extract info about a slide layout template."""
    info = {
        "name": layout.name,
        "placeholders": []
    }
    for ph in layout.placeholders:
        info["placeholders"].append({
            "idx": ph.placeholder_format.idx,
            "type": str(ph.placeholder_format.type),
            "name": ph.name,
            "position": {
                "left_in": emu_to_inches(ph.left),
                "top_in": emu_to_inches(ph.top),
                "width_in": emu_to_inches(ph.width),
                "height_in": emu_to_inches(ph.height),
            }
        })
    return info


def _hex_luminance(hex_str):
    """Compute perceived luminance (0-255) from a hex color string."""
    h = hex_str.lstrip("#")
    if len(h) != 6:
        return 128
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return 0.299 * r + 0.587 * g + 0.114 * b


def _is_near_white(hex_str, threshold=230):
    return _hex_luminance(hex_str) >= threshold


def _is_near_black(hex_str, threshold=40):
    return _hex_luminance(hex_str) <= threshold


def analyze_design_system(slides_data, all_colors, all_fonts, all_sizes,
                          text_colors=None, fill_colors=None,
                          bg_colors=None, border_colors=None):
    """Derive the design system from collected data with semantic color classification."""
    system = {}

    # Color palette — sorted by frequency (kept for backwards compatibility)
    color_counts = Counter(c for c in all_colors if c and not c.startswith("theme:"))
    if color_counts:
        system["color_palette"] = [
            {"hex": color, "uses": count}
            for color, count in color_counts.most_common(20)
        ]

    # Theme colors
    theme_colors = Counter(c for c in all_colors if c and c.startswith("theme:"))
    if theme_colors:
        system["theme_colors"] = [
            {"ref": color, "uses": count}
            for color, count in theme_colors.most_common()
        ]

    # === Semantic color classification ===
    # Classify colors by their actual role, not just frequency
    semantic = {}

    # Text colors: most common non-theme text color
    tc = Counter(c for c in (text_colors or []) if c and not c.startswith("theme:"))
    if tc:
        # Primary text = most frequent text color
        semantic["text_primary"] = tc.most_common(1)[0][0]
        # Secondary text = second most frequent, or a lighter variant
        if len(tc) >= 2:
            semantic["text_secondary"] = tc.most_common(2)[1][0]

    # Background colors: prefer slide backgrounds, then large shape fills
    bc = Counter(c for c in (bg_colors or []) if c and not c.startswith("theme:"))
    if bc:
        semantic["background"] = bc.most_common(1)[0][0]
    elif fill_colors:
        # If no explicit bg colors, use the lightest frequent fill color
        fc = Counter(c for c in fill_colors if c and not c.startswith("theme:"))
        light_fills = [(c, n) for c, n in fc.most_common(10) if _hex_luminance(c) > 180]
        if light_fills:
            semantic["background"] = light_fills[0][0]

    # Accent colors: fills that are NOT the background and NOT near-black/near-white
    bg_hex = semantic.get("background", "").lstrip("#").upper()
    text_hex = semantic.get("text_primary", "").lstrip("#").upper()

    fc_all = Counter(c for c in (fill_colors or []) if c and not c.startswith("theme:"))
    accent_candidates = [
        (c, n) for c, n in fc_all.most_common(20)
        if c.lstrip("#").upper() != bg_hex
        and c.lstrip("#").upper() != text_hex
        and not _is_near_white(c)
        and not _is_near_black(c)
    ]
    if accent_candidates:
        semantic["accent"] = accent_candidates[0][0]
        if len(accent_candidates) >= 2:
            semantic["accent2"] = accent_candidates[1][0]
    else:
        # No colorful accents found — look in ALL colors for non-text, non-bg
        all_notheme = Counter(c for c in all_colors if c and not c.startswith("theme:"))
        accent_from_all = [
            (c, n) for c, n in all_notheme.most_common(20)
            if c.lstrip("#").upper() != bg_hex
            and c.lstrip("#").upper() != text_hex
            and not _is_near_white(c)
            and not _is_near_black(c)
        ]
        if accent_from_all:
            semantic["accent"] = accent_from_all[0][0]
            if len(accent_from_all) >= 2:
                semantic["accent2"] = accent_from_all[1][0]

    # If we still don't have an accent (monochrome deck), derive from text
    if "accent" not in semantic and text_hex:
        semantic["accent"] = semantic.get("text_primary", "#333333")

    if semantic:
        system["semantic_colors"] = semantic

    # Typography
    font_counts = Counter(f for f in all_fonts if f)
    size_counts = Counter(s for s in all_sizes if s)
    system["typography"] = {
        "fonts_by_frequency": [
            {"font": font, "uses": count}
            for font, count in font_counts.most_common()
        ],
        "sizes_by_frequency": [
            {"size_pt": size, "uses": count}
            for size, count in size_counts.most_common()
        ],
    }

    # Detect text hierarchy
    if size_counts:
        sorted_sizes = sorted(size_counts.keys(), reverse=True)
        hierarchy = []
        role_names = ["title", "subtitle", "heading", "subheading", "body", "caption", "footnote"]
        for i, size in enumerate(sorted_sizes[:len(role_names)]):
            hierarchy.append({
                "likely_role": role_names[i],
                "size_pt": size,
                "uses": size_counts[size]
            })
        system["text_hierarchy"] = hierarchy

    return system


def derive_layout_patterns(slides_data):
    """Derive spatial layout patterns from per-slide shape data.

    Groups slides by layout name and computes median positions for
    identified shape roles (title, body, image, accent bar, etc.).
    Also derives global margin and spacing metrics.
    """
    from statistics import median

    layout_groups = {}
    for slide in slides_data:
        layout = slide.get("layout_name") or "Unknown"
        layout_groups.setdefault(layout, []).append(slide)

    layout_patterns = {}
    all_left_pcts = []
    all_right_edges = []
    all_top_pcts = []

    for layout_name, slides in layout_groups.items():
        roles = {}  # role -> list of position dicts

        for slide in slides:
            shapes = slide.get("shapes", [])
            # Sort shapes by top position to identify roles
            positioned = [(s, s.get("position", {})) for s in shapes if s.get("position")]
            if not positioned:
                continue

            # Identify title: top-most text shape with large font
            text_shapes = []
            for s, pos in positioned:
                tf = s.get("text_frame", {})
                paras = tf.get("paragraphs", [])
                if paras:
                    max_size = 0
                    for p in paras:
                        for r in p.get("runs", []):
                            sz = r.get("size_pt", 0)
                            if sz > max_size:
                                max_size = sz
                    if max_size > 0:
                        text_shapes.append((s, pos, max_size))

            # Sort by font size desc — largest is likely title
            text_shapes.sort(key=lambda x: x[2], reverse=True)

            if text_shapes:
                # Title: largest text
                _, tpos, _ = text_shapes[0]
                roles.setdefault("title", []).append(tpos)
                all_left_pcts.append(tpos.get("left_pct") or 5)
                right_edge = (tpos.get("left_pct") or 0) + (tpos.get("width_pct") or 0)
                all_right_edges.append(right_edge)
                all_top_pcts.append(tpos.get("top_pct") or 12)

                # Subtitle: second largest text (if notably smaller than title)
                if len(text_shapes) >= 2 and text_shapes[1][2] < text_shapes[0][2] * 0.85:
                    _, spos, _ = text_shapes[1]
                    roles.setdefault("subtitle", []).append(spos)

                # Body area: remaining text shapes
                for _, bpos, sz in text_shapes[2:]:
                    roles.setdefault("body_area", []).append(bpos)
                    all_left_pcts.append(bpos.get("left_pct") or 5)

            # Detect accent bars: thin shapes with fill, no text
            for s, pos in positioned:
                h = pos.get("height_pct", 100)
                w = pos.get("width_pct", 100)
                has_text = bool(s.get("text_frame", {}).get("paragraphs", []))
                has_fill = bool(s.get("fill"))

                if has_fill and not has_text:
                    if h is not None and h < 2 and w is not None and w > 5:  # Horizontal bar
                        roles.setdefault("accent_bar", []).append(pos)
                    elif w is not None and w < 2 and h is not None and h > 5:  # Vertical bar
                        roles.setdefault("accent_bar", []).append(pos)

            # Detect images
            for s, pos in positioned:
                if s.get("image"):
                    roles.setdefault("image", []).append(pos)

        # Compute median position for each role
        if roles:
            pattern = {}
            for role, positions in roles.items():
                if positions:
                    pattern[role] = {
                        "left_pct": round(median(p.get("left_pct", 0) or 0 for p in positions), 1),
                        "top_pct": round(median(p.get("top_pct", 0) or 0 for p in positions), 1),
                        "width_pct": round(median(p.get("width_pct", 0) or 0 for p in positions), 1),
                        "height_pct": round(median(p.get("height_pct", 0) or 0 for p in positions), 1),
                    }
            if pattern:
                layout_patterns[layout_name] = pattern

    # Derive global spacing metrics
    global_spacing = {}
    if all_left_pcts:
        global_spacing["margin_left_pct"] = round(median(all_left_pcts), 1)
    if all_right_edges:
        global_spacing["margin_right_pct"] = round(100 - median(all_right_edges), 1)
    if all_top_pcts:
        global_spacing["margin_top_pct"] = round(median(all_top_pcts), 1)
        # Content typically starts after title + some gap
        global_spacing["content_top_pct"] = round(median(all_top_pcts) + 10, 1)

    return {"layout_patterns": layout_patterns, "global_spacing": global_spacing}


def extract_ppt(filepath):
    """Main extraction function."""
    prs = Presentation(filepath)

    # Slide dimensions
    slide_width = prs.slide_width
    slide_height = prs.slide_height
    result = {
        "source_file": str(Path(filepath).name),
        "slide_dimensions": {
            "width_in": emu_to_inches(slide_width),
            "height_in": emu_to_inches(slide_height),
            "aspect_ratio": f"{round(slide_width/slide_height, 2)}:1" if slide_height else None,
            "width_emu": slide_width,
            "height_emu": slide_height,
        },
        "total_slides": len(prs.slides),
    }

    # Slide layouts available
    layouts = []
    for layout in prs.slide_layouts:
        layouts.append(extract_slide_layout_info(layout))
    result["available_layouts"] = layouts

    # Slide master colors (theme)
    try:
        master = prs.slide_masters[0]
        theme_info = {"name": master.name if hasattr(master, 'name') else None}
        # Try to extract theme colors from XML
        theme_el = master.element.find('.//{http://schemas.openxmlformats.org/drawingml/2006/main}clrScheme')
        if theme_el is not None:
            theme_colors = {}
            for child in theme_el:
                tag = child.tag.split('}')[-1] if '}' in child.tag else child.tag
                for sub in child:
                    if 'val' in sub.attrib:
                        theme_colors[tag] = f"#{sub.attrib['val']}"
                    elif 'lastClr' in sub.attrib:
                        theme_colors[tag] = f"#{sub.attrib['lastClr']}"
            if theme_colors:
                theme_info["color_scheme"] = theme_colors
        result["theme"] = theme_info
    except Exception:
        pass

    # Process each slide — track colors by semantic category
    all_colors = []
    text_colors = []
    fill_colors = []
    bg_colors = []
    border_colors = []
    all_fonts = []
    all_sizes = []
    slides_data = []

    for slide_idx, slide in enumerate(prs.slides):
        slide_info = {
            "slide_number": slide_idx + 1,
            "layout_name": slide.slide_layout.name if slide.slide_layout else None,
        }

        # Background
        try:
            bg = slide.background
            if bg.fill and bg.fill.type is not None:
                slide_info["background"] = extract_fill(bg)
                bg_color = extract_color(bg.fill.fore_color) if "SOLID" in str(bg.fill.type) else None
                if bg_color:
                    all_colors.append(bg_color)
                    bg_colors.append(bg_color)
        except Exception:
            pass

        # Shapes
        shapes = []
        for shape in slide.shapes:
            shape_info = extract_shape_info(shape, slide_width, slide_height)
            shapes.append(shape_info)

            # Collect colors by category for semantic analysis
            fill = shape_info.get("fill", {})
            if isinstance(fill, dict) and fill.get("color"):
                c = fill["color"]
                all_colors.append(c)
                fill_colors.append(c)

            border = shape_info.get("border", {})
            if isinstance(border, dict) and border.get("color"):
                c = border["color"]
                all_colors.append(c)
                border_colors.append(c)

            tf = shape_info.get("text_frame", {})
            for para in tf.get("paragraphs", []):
                for run in para.get("runs", []):
                    if run.get("font"):
                        all_fonts.append(run["font"])
                    if run.get("size_pt"):
                        all_sizes.append(run["size_pt"])
                    if run.get("color"):
                        c = run["color"]
                        all_colors.append(c)
                        text_colors.append(c)

        slide_info["shapes"] = shapes
        slide_info["shape_count"] = len(shapes)
        slides_data.append(slide_info)

    result["slides"] = slides_data

    # Derive design system with semantic color classification
    result["design_system"] = analyze_design_system(
        slides_data, all_colors, all_fonts, all_sizes,
        text_colors=text_colors, fill_colors=fill_colors,
        bg_colors=bg_colors, border_colors=border_colors
    )

    # Structural patterns
    layout_usage = Counter(s["layout_name"] for s in slides_data if s.get("layout_name"))
    result["layout_usage"] = [
        {"layout": name, "slides_using": count}
        for name, count in layout_usage.most_common()
    ]

    # Shape type frequency
    shape_types = Counter()
    for s in slides_data:
        for sh in s.get("shapes", []):
            st = sh.get("shape_type", "unknown")
            shape_types[st] += 1
    result["shape_type_frequency"] = [
        {"type": t, "count": c} for t, c in shape_types.most_common()
    ]

    # Derive spatial layout patterns and global spacing
    spatial = derive_layout_patterns(slides_data)
    result["layout_patterns"] = spatial.get("layout_patterns", {})
    result["global_spacing"] = spatial.get("global_spacing", {})

    # Derive visual effects summary
    visual_effects = {
        "has_shadows": False,
        "shadow_count": 0,
        "has_gradients": False,
        "gradient_count": 0,
        "shape_variety": [],
        "decorative_elements": [],
    }
    for slide in slides_data:
        for shape in slide.get("shapes", []):
            if shape.get("has_shadow"):
                visual_effects["has_shadows"] = True
                visual_effects["shadow_count"] += 1
            fill = shape.get("fill", {})
            if isinstance(fill, dict) and fill.get("gradient_stops"):
                visual_effects["has_gradients"] = True
                visual_effects["gradient_count"] += 1
            st = shape.get("shape_type", "")
            if st and st not in visual_effects["shape_variety"]:
                visual_effects["shape_variety"].append(st)
            # Detect decorative: shapes with fill but no text/table/chart/image
            has_content = bool(shape.get("text_frame", {}).get("paragraphs"))
            has_media = shape.get("table") or shape.get("chart") or shape.get("image")
            if not has_content and not has_media and fill:
                pos = shape.get("position", {})
                visual_effects["decorative_elements"].append({
                    "shape_type": st,
                    "fill": fill,
                    "position_pct": {
                        "left": pos.get("left_pct"),
                        "top": pos.get("top_pct"),
                        "width": pos.get("width_pct"),
                        "height": pos.get("height_pct"),
                    },
                })
    result["visual_effects"] = visual_effects

    # ── Design Philosophy Analysis ──
    # Analyze COMPOSITION: how elements relate to each other, not just what they are.
    # This is what separates "list of shapes" from "understanding the design."
    philosophy = {}

    # 1. Content density: how much text per slide on average?
    text_counts = []
    for slide in slides_data:
        char_count = 0
        for shape in slide.get("shapes", []):
            tf = shape.get("text_frame", {})
            for para in tf.get("paragraphs", []):
                for run in para.get("runs", []):
                    char_count += len(run.get("text", ""))
        text_counts.append(char_count)
    if text_counts:
        avg_chars = sum(text_counts) / len(text_counts)
        philosophy["content_density"] = (
            "minimal" if avg_chars < 80 else
            "moderate" if avg_chars < 200 else
            "dense" if avg_chars < 400 else
            "very_dense"
        )
        philosophy["avg_chars_per_slide"] = round(avg_chars)

    # 2. Whitespace ratio: how much of each slide is empty?
    coverage_pcts = []
    for slide in slides_data:
        total_area = 0
        for shape in slide.get("shapes", []):
            pos = shape.get("position", {})
            w = pos.get("width_pct", 0) or 0
            h = pos.get("height_pct", 0) or 0
            total_area += w * h / 100  # as percentage of slide
        coverage_pcts.append(min(total_area, 100))
    if coverage_pcts:
        avg_coverage = sum(coverage_pcts) / len(coverage_pcts)
        philosophy["whitespace_ratio"] = round(100 - avg_coverage)
        philosophy["whitespace_style"] = (
            "airy" if avg_coverage < 30 else
            "balanced" if avg_coverage < 55 else
            "compact" if avg_coverage < 75 else
            "dense"
        )

    # 3. Shape count per slide: simple vs complex layouts
    shape_counts = [slide.get("shape_count", 0) for slide in slides_data]
    if shape_counts:
        avg_shapes = sum(shape_counts) / len(shape_counts)
        philosophy["avg_shapes_per_slide"] = round(avg_shapes, 1)
        philosophy["layout_complexity"] = (
            "minimal" if avg_shapes < 4 else
            "clean" if avg_shapes < 7 else
            "moderate" if avg_shapes < 12 else
            "complex"
        )

    # 4. Text alignment preference
    align_counts = Counter()
    for slide in slides_data:
        for shape in slide.get("shapes", []):
            tf = shape.get("text_frame", {})
            for para in tf.get("paragraphs", []):
                a = para.get("alignment", "left")
                align_counts[a] += 1
    if align_counts:
        philosophy["dominant_alignment"] = align_counts.most_common(1)[0][0]
        philosophy["alignment_distribution"] = dict(align_counts.most_common())

    # 5. Color usage restraint
    unique_colors = set(c for c in all_colors if c and not c.startswith("theme:"))
    philosophy["color_palette_size"] = len(unique_colors)
    philosophy["color_restraint"] = (
        "monochrome" if len(unique_colors) <= 3 else
        "restrained" if len(unique_colors) <= 6 else
        "moderate" if len(unique_colors) <= 12 else
        "colorful"
    )

    # 6. Visual effects restraint
    total_shapes = sum(shape_counts) if shape_counts else 1
    philosophy["effects_usage"] = {
        "shadows": "none" if not visual_effects["has_shadows"] else
                   "sparse" if visual_effects["shadow_count"] / max(total_shapes, 1) < 0.1 else
                   "moderate" if visual_effects["shadow_count"] / max(total_shapes, 1) < 0.3 else
                   "heavy",
        "gradients": "none" if not visual_effects["has_gradients"] else
                     "sparse" if visual_effects["gradient_count"] / max(total_shapes, 1) < 0.1 else
                     "moderate" if visual_effects["gradient_count"] / max(total_shapes, 1) < 0.3 else
                     "heavy",
    }

    # 7. Layout variety: does the deck use the same layout or mix it up?
    layout_names = [s.get("layout_name") for s in slides_data if s.get("layout_name")]
    unique_layouts = len(set(layout_names))
    philosophy["layout_variety"] = (
        "uniform" if unique_layouts <= 2 else
        "moderate" if unique_layouts <= 4 else
        "varied"
    )

    # 8. Title style: are titles big/centered or small/left-aligned?
    title_aligns = []
    title_sizes = []
    for slide in slides_data:
        shapes = slide.get("shapes", [])
        if not shapes:
            continue
        # Find likely title (largest text, topmost)
        texts = []
        for s in shapes:
            tf = s.get("text_frame", {})
            for p in tf.get("paragraphs", []):
                for r in p.get("runs", []):
                    sz = r.get("size_pt", 0)
                    if sz > 0:
                        texts.append((sz, p.get("alignment", "left"), s.get("position", {})))
        if texts:
            texts.sort(key=lambda x: x[0], reverse=True)
            title_sizes.append(texts[0][0])
            title_aligns.append(texts[0][1])
    if title_aligns:
        philosophy["title_alignment"] = Counter(title_aligns).most_common(1)[0][0]
    if title_sizes:
        philosophy["avg_title_size_pt"] = round(sum(title_sizes) / len(title_sizes), 1)

    result["design_philosophy"] = philosophy

    return result


def to_markdown(data):
    """Convert extracted data to a readable markdown design language doc."""
    lines = []
    lines.append(f"# Design Language: {data['source_file']}")
    lines.append("")

    # Dimensions
    dim = data["slide_dimensions"]
    lines.append(f"## Slide Canvas")
    lines.append(f"- **Dimensions**: {dim['width_in']}\" × {dim['height_in']}\" (aspect {dim['aspect_ratio']})")
    lines.append(f"- **Total slides**: {data['total_slides']}")
    lines.append("")

    # Theme
    theme = data.get("theme", {})
    if theme.get("color_scheme"):
        lines.append("## Theme Color Scheme")
        for name, color in theme["color_scheme"].items():
            lines.append(f"- **{name}**: `{color}`")
        lines.append("")

    # Design system
    ds = data.get("design_system", {})

    if ds.get("color_palette"):
        lines.append("## Color Palette (by frequency)")
        for c in ds["color_palette"]:
            lines.append(f"- `{c['hex']}` — used {c['uses']}×")
        lines.append("")

    if ds.get("typography"):
        typo = ds["typography"]
        if typo.get("fonts_by_frequency"):
            lines.append("## Fonts")
            for f in typo["fonts_by_frequency"]:
                lines.append(f"- **{f['font']}** — used {f['uses']}×")
            lines.append("")
        if typo.get("sizes_by_frequency"):
            lines.append("## Text Sizes")
            for s in typo["sizes_by_frequency"]:
                lines.append(f"- **{s['size_pt']}pt** — used {s['uses']}×")
            lines.append("")

    if ds.get("text_hierarchy"):
        lines.append("## Text Hierarchy (inferred)")
        for h in ds["text_hierarchy"]:
            lines.append(f"- **{h['likely_role']}**: {h['size_pt']}pt ({h['uses']}× occurrences)")
        lines.append("")

    # Layout usage
    if data.get("layout_usage"):
        lines.append("## Layout Usage")
        for l in data["layout_usage"]:
            lines.append(f"- **{l['layout']}**: {l['slides_using']} slides")
        lines.append("")

    # Per-slide blueprint
    lines.append("## Slide-by-Slide Blueprint")
    lines.append("")
    for slide in data.get("slides", []):
        lines.append(f"### Slide {slide['slide_number']} — Layout: {slide.get('layout_name', 'unknown')}")
        if slide.get("background"):
            bg = slide["background"]
            lines.append(f"- **Background**: {bg.get('type', 'none')}, color: {bg.get('color', 'n/a')}")

        for shape in slide.get("shapes", []):
            pos = shape.get("position", {})
            pos_str = f"({pos.get('left_pct', '?')}%, {pos.get('top_pct', '?')}%) → {pos.get('width_pct', '?')}% × {pos.get('height_pct', '?')}%"

            shape_type = shape.get("shape_type", "")
            name = shape.get("name", "")

            # Placeholder
            ph = shape.get("placeholder")
            if ph:
                lines.append(f"- **[{ph['type']}]** `{name}` at {pos_str}")
            else:
                lines.append(f"- **{shape_type}** `{name}` at {pos_str}")

            # Fill
            fill = shape.get("fill")
            if fill and fill.get("color"):
                lines.append(f"  - Fill: `{fill['color']}`")

            # Text
            tf = shape.get("text_frame", {})
            for para in tf.get("paragraphs", []):
                for run in para.get("runs", []):
                    text_preview = run["text"][:60] + ("..." if len(run["text"]) > 60 else "")
                    font_str = run.get("font", "?")
                    size_str = run.get("size_pt", "?")
                    style = ""
                    if run.get("bold"):
                        style += "B"
                    if run.get("italic"):
                        style += "I"
                    lines.append(f"  - Text: \"{text_preview}\" — {font_str} {size_str}pt {style} {run.get('color', '')}".rstrip())

            # Table
            if shape.get("table"):
                t = shape["table"]
                lines.append(f"  - Table: {t['rows']}×{t['cols']}")

            # Image
            if shape.get("image"):
                img = shape["image"]
                lines.append(f"  - Image: {img.get('content_type', 'unknown')}")

            # Chart
            if shape.get("chart"):
                ch = shape["chart"]
                lines.append(f"  - Chart: {ch.get('chart_type', 'unknown')}, {ch.get('series_count', 0)} series")

        lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Extract design language from a PowerPoint file",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python ppt_design_extractor.py presentation.pptx
  python ppt_design_extractor.py deck.pptx -o design.json
  python ppt_design_extractor.py deck.pptx --format markdown -o design.md
  python ppt_design_extractor.py deck.pptx --format both -o design
        """
    )
    parser.add_argument("input", help="Path to .pptx file")
    parser.add_argument("-o", "--output", help="Output file path (default: stdout for json, auto-named for markdown)")
    parser.add_argument("--format", choices=["json", "markdown", "both"], default="both",
                        help="Output format (default: both)")

    args = parser.parse_args()

    if not Path(args.input).exists():
        print(f"Error: File not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    print(f"Extracting design language from: {args.input}", file=sys.stderr)
    data = extract_ppt(args.input)

    if args.format in ("json", "both"):
        json_out = args.output if args.format == "json" else (f"{args.output}.json" if args.output else None)
        json_str = json.dumps(data, indent=2, ensure_ascii=False)
        if json_out:
            Path(json_out).write_text(json_str, encoding="utf-8")
            print(f"JSON written to: {json_out}", file=sys.stderr)
        else:
            print(json_str)

    if args.format in ("markdown", "both"):
        md_out = args.output if args.format == "markdown" else (f"{args.output}.md" if args.output else None)
        md_str = to_markdown(data)
        if md_out:
            Path(md_out).write_text(md_str, encoding="utf-8")
            print(f"Markdown written to: {md_out}", file=sys.stderr)
        else:
            print(md_str)

    # Summary
    ds = data.get("design_system", {})
    colors = len(ds.get("color_palette", []))
    fonts = len(ds.get("typography", {}).get("fonts_by_frequency", []))
    print(f"\nExtracted: {data['total_slides']} slides, {colors} colors, {fonts} fonts", file=sys.stderr)


if __name__ == "__main__":
    main()
