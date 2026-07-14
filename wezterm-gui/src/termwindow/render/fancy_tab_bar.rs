use crate::customglyph::*;
use crate::tabbar::{TabBarItem, TabEntry};
use crate::termwindow::box_model::*;
use crate::termwindow::render::corners::*;

use crate::termwindow::render::window_buttons::window_button_element;
use crate::termwindow::{UIItem, UIItemType};
use crate::utilsprites::RenderMetrics;
use config::{Dimension, DimensionContext, TabBarColors, TabBarPosition};
use std::rc::Rc;
use termwiz::color::SrgbaTuple;
use termwiz::surface::SEQ_ZERO;
use wezterm_font::LoadedFont;
use wezterm_term::{
    color::{ColorAttribute, ColorPalette},
    Line,
};
use window::{IntegratedTitleButtonAlignment, IntegratedTitleButtonStyle};

const X_BUTTON: &[Poly] = &[
    Poly {
        path: &[
            PolyCommand::MoveTo(BlockCoord::One, BlockCoord::Zero),
            PolyCommand::LineTo(BlockCoord::Zero, BlockCoord::One),
        ],
        intensity: BlockAlpha::Full,
        style: PolyStyle::Outline,
    },
    Poly {
        path: &[
            PolyCommand::MoveTo(BlockCoord::Zero, BlockCoord::Zero),
            PolyCommand::LineTo(BlockCoord::One, BlockCoord::One),
        ],
        intensity: BlockAlpha::Full,
        style: PolyStyle::Outline,
    },
];

const PLUS_BUTTON: &[Poly] = &[
    Poly {
        path: &[
            PolyCommand::MoveTo(BlockCoord::Frac(1, 2), BlockCoord::Zero),
            PolyCommand::LineTo(BlockCoord::Frac(1, 2), BlockCoord::One),
        ],
        intensity: BlockAlpha::Full,
        style: PolyStyle::Outline,
    },
    Poly {
        path: &[
            PolyCommand::MoveTo(BlockCoord::Zero, BlockCoord::Frac(1, 2)),
            PolyCommand::LineTo(BlockCoord::One, BlockCoord::Frac(1, 2)),
        ],
        intensity: BlockAlpha::Full,
        style: PolyStyle::Outline,
    },
];

const CATEGORY_BUTTON: &[Poly] = &[
    Poly {
        path: &[
            PolyCommand::MoveTo(BlockCoord::Zero, BlockCoord::Frac(1, 4)),
            PolyCommand::LineTo(BlockCoord::One, BlockCoord::Frac(1, 4)),
        ],
        intensity: BlockAlpha::Full,
        style: PolyStyle::Outline,
    },
    Poly {
        path: &[
            PolyCommand::MoveTo(BlockCoord::Zero, BlockCoord::Frac(1, 2)),
            PolyCommand::LineTo(BlockCoord::One, BlockCoord::Frac(1, 2)),
        ],
        intensity: BlockAlpha::Full,
        style: PolyStyle::Outline,
    },
    Poly {
        path: &[
            PolyCommand::MoveTo(BlockCoord::Zero, BlockCoord::Frac(3, 4)),
            PolyCommand::LineTo(BlockCoord::One, BlockCoord::Frac(3, 4)),
        ],
        intensity: BlockAlpha::Full,
        style: PolyStyle::Outline,
    },
];

fn trim_status_line_edges(line: &mut Line) {
    while line.len() > 0 {
        let trim = line
            .get_cell(0)
            .map(|cell| matches!(cell.str(), " " | "·"))
            .unwrap_or(false);
        if !trim {
            break;
        }
        line.remove_cell(0, SEQ_ZERO);
    }

    while line.len() > 0 {
        let trim = line
            .get_cell(line.len() - 1)
            .map(|cell| matches!(cell.str(), " " | "·"))
            .unwrap_or(false);
        if !trim {
            break;
        }
        line.remove_cell(line.len() - 1, SEQ_ZERO);
    }
}

fn wrap_vertical_status(mut line: Line, max_cols: usize) -> Vec<Line> {
    let max_cols = max_cols.max(8);
    for cell in line.cells_mut_for_attr_changes_only() {
        cell.attrs_mut().set_background(ColorAttribute::Default);
    }
    trim_status_line_edges(&mut line);
    let mut rows = vec![];

    while line.len() > max_cols {
        let mut split_at = max_cols;
        for idx in (1..max_cols).rev() {
            if line
                .get_cell(idx)
                .map(|cell| cell.str() == "·")
                .unwrap_or(false)
            {
                split_at = idx.saturating_sub(1).max(1);
                break;
            }
        }

        let mut rest = line.split_off(split_at, SEQ_ZERO);
        trim_status_line_edges(&mut line);
        trim_status_line_edges(&mut rest);
        if line.len() > 0 {
            rows.push(line);
        }
        line = rest;
    }

    if line.len() > 0 {
        rows.push(line);
    }
    rows
}

fn rounded_corners(radius: f32) -> Corners {
    Corners {
        top_left: SizedPoly {
            width: Dimension::Cells(radius),
            height: Dimension::Cells(radius),
            poly: TOP_LEFT_ROUNDED_CORNER,
        },
        top_right: SizedPoly {
            width: Dimension::Cells(radius),
            height: Dimension::Cells(radius),
            poly: TOP_RIGHT_ROUNDED_CORNER,
        },
        bottom_left: SizedPoly {
            width: Dimension::Cells(radius),
            height: Dimension::Cells(radius),
            poly: BOTTOM_LEFT_ROUNDED_CORNER,
        },
        bottom_right: SizedPoly {
            width: Dimension::Cells(radius),
            height: Dimension::Cells(radius),
            poly: BOTTOM_RIGHT_ROUNDED_CORNER,
        },
    }
}

fn is_vertical_tab_list_item(element: &ComputedElement) -> bool {
    matches!(
        element.item_type,
        Some(UIItemType::TabBar(
            TabBarItem::Tab { .. } | TabBarItem::GroupHeader { .. }
        ))
    )
}

fn is_active_vertical_tab(element: &ComputedElement) -> bool {
    matches!(
        element.item_type,
        Some(UIItemType::TabBar(TabBarItem::Tab { active: true, .. }))
    )
}

fn fit_vertical_tab_stack(stack: &mut ComputedElement, max_height: f32, origin_y: f32) {
    let children = match &mut stack.content {
        ComputedElementContent::Children(children) => children,
        _ => return,
    };
    let first = match children.iter().position(is_vertical_tab_list_item) {
        Some(first) => first,
        None => return,
    };
    let last = children
        .iter()
        .rposition(is_vertical_tab_list_item)
        .map(|last| last + 1)
        .unwrap_or(first);
    let fixed_height = children[..first]
        .iter()
        .chain(children[last..].iter())
        .map(|child| child.bounds.height())
        .sum::<f32>();
    let list_capacity = (max_height - fixed_height).max(0.);
    let active = children[first..last]
        .iter()
        .position(is_active_vertical_tab)
        .map(|idx| first + idx)
        .unwrap_or(first);

    let mut start = active;
    let mut end = (active + 1).min(last);
    let mut used = children[active].bounds.height();
    let mut prefer_before = true;
    loop {
        let before = start.checked_sub(1).filter(|idx| *idx >= first);
        let after = (end < last).then_some(end);
        if before.is_none() && after.is_none() {
            break;
        }

        let candidates = if prefer_before {
            [before, after]
        } else {
            [after, before]
        };
        let mut added = false;
        for candidate in candidates.iter().copied().flatten() {
            let height = children[candidate].bounds.height();
            if used + height <= list_capacity {
                used += height;
                if candidate < start {
                    start = candidate;
                } else {
                    end = candidate + 1;
                }
                added = true;
                break;
            }
        }
        if !added {
            break;
        }
        prefer_before = !prefer_before;
    }

    while end > start
        && matches!(
            children[end - 1].item_type,
            Some(UIItemType::TabBar(TabBarItem::GroupHeader { .. }))
        )
    {
        end -= 1;
    }

    let mut original: Vec<Option<ComputedElement>> =
        std::mem::take(children).into_iter().map(Some).collect();
    let mut selected = vec![];
    let mut y = origin_y;
    for idx in (0..first).chain(start..end).chain(last..original.len()) {
        let mut child = original[idx].take().unwrap();
        let height = child.bounds.height();
        child.translate(euclid::vec2(0., y - child.bounds.min_y()));
        y += height;
        selected.push(child);
    }
    *children = selected;
}

impl crate::TermWindow {
    pub fn invalidate_fancy_tab_bar(&mut self) {
        self.fancy_tab_bar.take();
    }

    pub fn build_fancy_tab_bar(&self, palette: &ColorPalette) -> anyhow::Result<ComputedElement> {
        let pos = self.resolved_tab_bar_position();
        if pos.is_vertical() {
            self.build_vertical_fancy_tab_bar(palette, pos)
        } else {
            self.build_horizontal_fancy_tab_bar(palette, pos)
        }
    }

    /// Build the horizontal fancy tab bar (Top/Bottom positions).
    /// This is the original build_fancy_tab_bar logic.
    fn build_horizontal_fancy_tab_bar(
        &self,
        palette: &ColorPalette,
        pos: TabBarPosition,
    ) -> anyhow::Result<ComputedElement> {
        let tab_bar_height = self.tab_bar_pixel_height()?;
        let font = self.fonts.title_font()?;
        let metrics = RenderMetrics::with_font_metrics(&font.metrics());
        let items = self.tab_bar.items();
        let colors = self
            .config
            .colors
            .as_ref()
            .and_then(|c| c.tab_bar.as_ref())
            .cloned()
            .unwrap_or_else(TabBarColors::default);

        let mut left_status = vec![];
        let mut left_eles = vec![];
        let mut right_eles = vec![];
        let bar_colors = self.tab_bar_colors();

        let item_to_elem = |item: &TabEntry| -> Element {
            self.tab_item_to_element(item, &font, &metrics, palette, &colors, &bar_colors, false)
        };

        let num_tabs: f32 = items
            .iter()
            .map(|item| match item.item {
                TabBarItem::NewTabButton | TabBarItem::Tab { .. } => 1.,
                _ => 0.,
            })
            .sum();
        let max_tab_width = ((self.dimensions.pixel_width as f32 / num_tabs)
            - (1.5 * metrics.cell_size.width as f32))
            .max(0.);

        // Reserve space for the native titlebar buttons
        if self
            .config
            .window_decorations
            .contains(::window::WindowDecorations::INTEGRATED_BUTTONS)
            && self.config.integrated_title_button_style == IntegratedTitleButtonStyle::MacOsNative
            && !self.window_state.contains(window::WindowState::FULL_SCREEN)
        {
            left_status.push(
                Element::new(&font, ElementContent::Text("".to_string())).margin(BoxDimension {
                    left: Dimension::Cells(4.0), // FIXME: determine exact width of macos ... buttons
                    right: Dimension::Cells(0.),
                    top: Dimension::Cells(0.),
                    bottom: Dimension::Cells(0.),
                }),
            );
        }

        for item in items {
            match item.item {
                TabBarItem::LeftStatus => left_status.push(item_to_elem(item)),
                TabBarItem::None | TabBarItem::RightStatus => right_eles.push(item_to_elem(item)),
                TabBarItem::WindowButton(_) => {
                    if self.config.integrated_title_button_alignment
                        == IntegratedTitleButtonAlignment::Left
                    {
                        left_eles.push(item_to_elem(item))
                    } else {
                        right_eles.push(item_to_elem(item))
                    }
                }
                TabBarItem::Tab { tab_idx, active } => {
                    let mut elem = item_to_elem(item);
                    elem.max_width = Some(Dimension::Pixels(max_tab_width));
                    elem.content = match elem.content {
                        ElementContent::Text(_) => unreachable!(),
                        ElementContent::Poly { .. } => unreachable!(),
                        ElementContent::Children(mut kids) => {
                            if self.config.show_close_tab_button_in_tabs {
                                kids.push(make_x_button(&font, &metrics, &colors, tab_idx, active));
                            }
                            ElementContent::Children(kids)
                        }
                    };
                    left_eles.push(elem);
                }
                _ => left_eles.push(item_to_elem(item)),
            }
        }

        let mut children = vec![];

        if !left_status.is_empty() {
            children.push(
                Element::new(&font, ElementContent::Children(left_status))
                    .colors(bar_colors.clone()),
            );
        }

        let window_buttons_at_left = self
            .config
            .window_decorations
            .contains(window::WindowDecorations::INTEGRATED_BUTTONS)
            && (self.config.integrated_title_button_alignment
                == IntegratedTitleButtonAlignment::Left
                || self.config.integrated_title_button_style
                    == IntegratedTitleButtonStyle::MacOsNative);

        let left_padding = if window_buttons_at_left {
            if self.config.integrated_title_button_style == IntegratedTitleButtonStyle::MacOsNative
            {
                if !self.window_state.contains(window::WindowState::FULL_SCREEN) {
                    Dimension::Pixels(70.0)
                } else {
                    Dimension::Cells(0.5)
                }
            } else {
                Dimension::Pixels(0.0)
            }
        } else {
            Dimension::Cells(0.5)
        };

        children.push(
            Element::new(&font, ElementContent::Children(left_eles))
                .vertical_align(VerticalAlign::Bottom)
                .colors(bar_colors.clone())
                .padding(BoxDimension {
                    left: left_padding,
                    right: Dimension::Cells(0.),
                    top: Dimension::Cells(0.),
                    bottom: Dimension::Cells(0.),
                })
                .zindex(1),
        );
        children.push(
            Element::new(&font, ElementContent::Children(right_eles))
                .colors(bar_colors.clone())
                .float(Float::Right),
        );

        let content = ElementContent::Children(children);

        let tabs = Element::new(&font, content)
            .display(DisplayType::Block)
            .item_type(UIItemType::TabBar(TabBarItem::None))
            .min_width(Some(Dimension::Pixels(self.dimensions.pixel_width as f32)))
            .min_height(Some(Dimension::Pixels(tab_bar_height)))
            .vertical_align(VerticalAlign::Bottom)
            .colors(bar_colors);

        let border = self.get_os_border();

        let mut computed = self.compute_element(
            &LayoutContext {
                height: DimensionContext {
                    dpi: self.dimensions.dpi as f32,
                    pixel_max: self.dimensions.pixel_height as f32,
                    pixel_cell: metrics.cell_size.height as f32,
                },
                width: DimensionContext {
                    dpi: self.dimensions.dpi as f32,
                    pixel_max: self.dimensions.pixel_width as f32,
                    pixel_cell: metrics.cell_size.width as f32,
                },
                bounds: euclid::rect(
                    border.left.get() as f32,
                    0.,
                    self.dimensions.pixel_width as f32 - (border.left + border.right).get() as f32,
                    tab_bar_height,
                ),
                metrics: &metrics,
                gl_state: self.render_state.as_ref().unwrap(),
                zindex: 10,
            },
            &tabs,
        )?;

        computed.translate(euclid::vec2(
            0.,
            if pos == TabBarPosition::Bottom {
                self.dimensions.pixel_height as f32
                    - (computed.bounds.height() + border.bottom.get() as f32)
            } else {
                border.top.get() as f32
            },
        ));

        Ok(computed)
    }

    /// Build the vertical fancy tab bar (Left/Right positions).
    /// Tabs are stacked vertically in a column with configurable width.
    fn build_vertical_fancy_tab_bar(
        &self,
        palette: &ColorPalette,
        pos: TabBarPosition,
    ) -> anyhow::Result<ComputedElement> {
        let tab_bar_width = self.tab_bar_pixel_width();
        let font = self.fonts.title_font()?;
        let metrics = RenderMetrics::with_font_metrics(&font.metrics());
        let items = self.tab_bar.items();
        let colors = self
            .config
            .colors
            .as_ref()
            .and_then(|c| c.tab_bar.as_ref())
            .cloned()
            .unwrap_or_else(TabBarColors::default);

        let bar_colors = self.tab_bar_colors();
        let footer_margin = metrics.cell_size.width as f32 * 0.45;
        let footer_padding = metrics.cell_size.width as f32 * 0.45;
        let footer_width = (tab_bar_width - footer_margin * 2.).max(0.);
        let footer_content_width = (footer_width - footer_padding * 2.).max(0.);

        // For vertical layout, each tab is a Block element stacked vertically.
        // Important: we override vertical_align to Top for all children because
        // the parent container has min_height = window_height. With Bottom or Middle
        // alignment, all children would be translated to overlap at the bottom/middle
        // of the window instead of stacking from the top.
        let mut tab_eles = vec![];
        let mut tab_action_buttons = vec![];
        let mut bottom_status = None;
        let mut inside_group = false;

        if self
            .config
            .window_decorations
            .contains(window::WindowDecorations::INTEGRATED_BUTTONS)
            && self.config.integrated_title_button_style == IntegratedTitleButtonStyle::MacOsNative
            && !self.window_state.contains(window::WindowState::FULL_SCREEN)
        {
            tab_eles.push(
                Element::new(&font, ElementContent::Text(String::new()))
                    .display(DisplayType::Block)
                    .min_width(Some(Dimension::Pixels(tab_bar_width)))
                    .max_width(Some(Dimension::Pixels(tab_bar_width)))
                    .min_height(Some(Dimension::Pixels(
                        metrics.cell_size.height as f32 * 2.8,
                    ))),
            );
        }

        for item in items {
            if let (TabBarItem::Tab { tab_idx, .. }, Some(group)) =
                (item.item, item.group.as_deref())
            {
                tab_eles.push(self.vertical_group_header_element(
                    &font,
                    &metrics,
                    &colors,
                    &bar_colors,
                    tab_bar_width,
                    tab_idx,
                    group,
                ));
                inside_group = true;
            }

            match item.item {
                TabBarItem::LeftStatus | TabBarItem::None => {
                    let mut elem = self.tab_item_to_element(
                        item,
                        &font,
                        &metrics,
                        palette,
                        &colors,
                        &bar_colors,
                        true,
                    );
                    elem.display = DisplayType::Block;
                    elem.vertical_align = VerticalAlign::Top;
                    elem.min_width = Some(Dimension::Pixels(tab_bar_width));
                    elem.max_width = Some(Dimension::Pixels(tab_bar_width));
                    tab_eles.push(elem);
                }
                TabBarItem::RightStatus => {
                    let max_cols = (footer_content_width / metrics.cell_size.width as f32) as usize;
                    let status_lines =
                        wrap_vertical_status(item.title.clone(), max_cols.saturating_sub(2));
                    let wrapped = status_lines.len() > 1;
                    let rows = status_lines
                        .into_iter()
                        .map(|line| {
                            let mut status_item = item.clone();
                            status_item.title = line;
                            let mut row = self.tab_item_to_element(
                                &status_item,
                                &font,
                                &metrics,
                                palette,
                                &colors,
                                &bar_colors,
                                true,
                            );
                            row.display = DisplayType::Block;
                            row.vertical_align = VerticalAlign::Top;
                            if wrapped {
                                row.line_height = Some(1.0);
                            }
                            row.colors.bg = InheritableColor::Inherited;
                            row.padding = BoxDimension::default();
                            row.margin = BoxDimension::default();
                            row.border = BoxDimension::default();
                            row.min_width = Some(Dimension::Pixels(footer_content_width));
                            row.max_width = Some(Dimension::Pixels(footer_content_width));
                            row
                        })
                        .collect();
                    let mut footer_border =
                        BorderColor::new(colors.inactive_tab_edge().to_linear());
                    footer_border.top = colors.active_tab().fg_color.to_linear().mul_alpha(0.55);
                    bottom_status = Some(
                        Element::new(&font, ElementContent::Children(rows))
                            .display(DisplayType::Inline)
                            .float(Float::Right)
                            .vertical_align(VerticalAlign::Bottom)
                            .zindex(2)
                            .margin(BoxDimension {
                                left: Dimension::Pixels(footer_margin),
                                right: Dimension::Pixels(footer_margin),
                                top: Dimension::Cells(0.35),
                                bottom: Dimension::Cells(0.35),
                            })
                            .padding(BoxDimension {
                                left: Dimension::Pixels(footer_padding),
                                right: Dimension::Pixels(footer_padding),
                                top: Dimension::Cells(0.3),
                                bottom: Dimension::Cells(0.35),
                            })
                            .border(BoxDimension::new(Dimension::Pixels(1.)))
                            .border_corners(Some(rounded_corners(0.5)))
                            .colors(ElementColors {
                                border: footer_border,
                                bg: colors.inactive_tab_hover().bg_color.to_linear().into(),
                                text: bar_colors.text.clone(),
                            })
                            .min_width(Some(Dimension::Pixels(footer_width)))
                            .max_width(Some(Dimension::Pixels(footer_width))),
                    );
                }
                TabBarItem::GroupHeader { .. } => {}
                TabBarItem::WindowButton(_) => {
                    // Skip window buttons in vertical mode
                }
                TabBarItem::Tab { tab_idx, active } => {
                    let mut elem = self.tab_item_to_element(
                        item,
                        &font,
                        &metrics,
                        palette,
                        &colors,
                        &bar_colors,
                        true,
                    );
                    // In vertical mode, tabs fill the full bar width and stack
                    elem.display = DisplayType::Block;
                    elem.vertical_align = VerticalAlign::Top;
                    let indent = if inside_group {
                        metrics.cell_size.width as f32 * 0.55
                    } else {
                        0.
                    };
                    elem.margin.left = Dimension::Pixels(indent);
                    elem.min_width = Some(Dimension::Pixels(tab_bar_width - indent));
                    elem.max_width = Some(Dimension::Pixels(tab_bar_width - indent));
                    // Round all four corners equally for vertical tabs
                    elem.border_corners = Some(rounded_corners(0.5));
                    let title_kids = match elem.content {
                        ElementContent::Text(_) => unreachable!(),
                        ElementContent::Poly { .. } => unreachable!(),
                        ElementContent::Children(kids) => kids,
                    };
                    let tab_inner_width =
                        (tab_bar_width - indent - metrics.cell_size.width as f32).max(0.);
                    let close_button_width = if self.config.show_close_tab_button_in_tabs {
                        metrics.cell_size.width as f32 * 2.5
                    } else {
                        0.
                    };
                    let title_text = Element::new(&font, ElementContent::Children(title_kids))
                        .max_width(Some(Dimension::Pixels(
                            (tab_inner_width - close_button_width).max(0.),
                        )));
                    let mut title_row_kids = vec![title_text];
                    if self.config.show_close_tab_button_in_tabs {
                        title_row_kids
                            .push(make_x_button(&font, &metrics, &colors, tab_idx, active));
                    }
                    let title_row = Element::new(&font, ElementContent::Children(title_row_kids))
                        .display(DisplayType::Block)
                        .min_width(Some(Dimension::Pixels(tab_inner_width)))
                        .max_width(Some(Dimension::Pixels(tab_inner_width)));
                    elem.content = if let Some(subtitle) = item.subtitle.as_deref() {
                        let subtitle_row =
                            Element::new(&font, ElementContent::Text(format!("    ({subtitle})")))
                                .display(DisplayType::Block)
                                .line_height(Some(0.9))
                                .max_width(Some(Dimension::Pixels(tab_inner_width)))
                                .colors(ElementColors {
                                    border: BorderColor::default(),
                                    bg: InheritableColor::Inherited,
                                    text: self
                                        .config
                                        .window_frame
                                        .inactive_titlebar_fg
                                        .to_linear()
                                        .into(),
                                });
                        elem.padding.bottom = Dimension::Cells(0.18);
                        ElementContent::Children(vec![title_row, subtitle_row])
                    } else {
                        ElementContent::Children(vec![title_row])
                    };
                    tab_eles.push(elem);
                }
                TabBarItem::NewTabButton | TabBarItem::NewGroupButton { .. } => {
                    let mut elem = self.tab_item_to_element(
                        item,
                        &font,
                        &metrics,
                        palette,
                        &colors,
                        &bar_colors,
                        true,
                    );
                    let first = matches!(item.item, TabBarItem::NewTabButton);
                    elem.margin = BoxDimension {
                        left: Dimension::Cells(if first { 0.55 } else { 0.2 }),
                        right: Dimension::Cells(0.1),
                        top: Dimension::Cells(0.25),
                        bottom: Dimension::Cells(0.3),
                    };
                    elem.padding = BoxDimension {
                        left: Dimension::Cells(0.65),
                        right: Dimension::Cells(0.65),
                        top: Dimension::Cells(0.25),
                        bottom: Dimension::Cells(0.3),
                    };
                    elem.border_corners = Some(rounded_corners(0.35));
                    tab_action_buttons.push(elem);
                    if matches!(item.item, TabBarItem::NewGroupButton { .. }) {
                        let mut toolbar_border = BorderColor::default();
                        toolbar_border.bottom = colors.inactive_tab_edge().to_linear();
                        tab_eles.push(
                            Element::new(
                                &font,
                                ElementContent::Children(std::mem::take(&mut tab_action_buttons)),
                            )
                            .display(DisplayType::Block)
                            .vertical_align(VerticalAlign::Top)
                            .border(BoxDimension {
                                left: Dimension::Pixels(0.),
                                right: Dimension::Pixels(0.),
                                top: Dimension::Pixels(0.),
                                bottom: Dimension::Pixels(1.),
                            })
                            .colors(ElementColors {
                                border: toolbar_border,
                                bg: InheritableColor::Inherited,
                                text: bar_colors.text.clone(),
                            })
                            .min_width(Some(Dimension::Pixels(tab_bar_width)))
                            .max_width(Some(Dimension::Pixels(tab_bar_width))),
                        );
                    }
                }
            }
        }

        if !tab_action_buttons.is_empty() {
            tab_eles.push(
                Element::new(&font, ElementContent::Children(tab_action_buttons))
                    .display(DisplayType::Block)
                    .vertical_align(VerticalAlign::Top)
                    .min_width(Some(Dimension::Pixels(tab_bar_width)))
                    .max_width(Some(Dimension::Pixels(tab_bar_width))),
            );
        }

        let border = self.get_os_border();
        let available_height =
            self.dimensions.pixel_height as f32 - (border.top + border.bottom).get() as f32;
        let tab_stack = Element::new(&font, ElementContent::Children(tab_eles))
            .display(DisplayType::Block)
            .vertical_align(VerticalAlign::Top)
            .min_width(Some(Dimension::Pixels(tab_bar_width)))
            .max_width(Some(Dimension::Pixels(tab_bar_width)));
        let tabs = Element::new(&font, ElementContent::Children(vec![]))
            .display(DisplayType::Block)
            .item_type(UIItemType::TabBar(TabBarItem::None))
            .min_width(Some(Dimension::Pixels(tab_bar_width)))
            .min_height(Some(Dimension::Pixels(available_height)))
            .colors(bar_colors);

        let layout_context = LayoutContext {
            height: DimensionContext {
                dpi: self.dimensions.dpi as f32,
                pixel_max: self.dimensions.pixel_height as f32,
                pixel_cell: metrics.cell_size.height as f32,
            },
            width: DimensionContext {
                dpi: self.dimensions.dpi as f32,
                pixel_max: tab_bar_width,
                pixel_cell: metrics.cell_size.width as f32,
            },
            bounds: euclid::rect(0., border.top.get() as f32, tab_bar_width, available_height),
            metrics: &metrics,
            gl_state: self.render_state.as_ref().unwrap(),
            zindex: 10,
        };

        let mut footer = bottom_status
            .map(|status| self.compute_element(&layout_context, &status))
            .transpose()?;
        let footer_height = footer
            .as_ref()
            .map(|footer| footer.bounds.height())
            .unwrap_or(0.);
        let top_height = (available_height - footer_height).max(0.);
        let mut tab_stack = self.compute_element(&layout_context, &tab_stack)?;
        if tab_stack.bounds.height() > top_height {
            fit_vertical_tab_stack(&mut tab_stack, top_height, layout_context.bounds.min_y());
        }
        let mut children = vec![tab_stack];
        if let Some(mut footer) = footer.take() {
            let target_y = layout_context.bounds.min_y() + available_height - footer_height;
            footer.translate(euclid::vec2(0., target_y - footer.bounds.min_y()));
            children.push(footer);
        }

        let mut computed = self.compute_element(&layout_context, &tabs)?;
        computed.content = ComputedElementContent::Children(children);

        // Position the tab bar on the correct side
        let translate_x = if pos == TabBarPosition::Right {
            self.dimensions.pixel_width as f32 - tab_bar_width - border.right.get() as f32
        } else {
            // Left
            border.left.get() as f32
        };
        computed.translate(euclid::vec2(translate_x, 0.));

        Ok(computed)
    }

    fn vertical_group_header_element(
        &self,
        font: &Rc<LoadedFont>,
        metrics: &RenderMetrics,
        colors: &TabBarColors,
        bar_colors: &ElementColors,
        tab_bar_width: f32,
        tab_idx: usize,
        group: &str,
    ) -> Element {
        let mut border = BorderColor::default();
        border.bottom = colors.inactive_tab_edge().to_linear();
        let horizontal_padding = metrics.cell_size.width as f32 * 0.85;
        let dragging = matches!(
            self.dragging
                .as_ref()
                .map(|(item, _)| &item.item_type),
            Some(UIItemType::TabBar(TabBarItem::GroupHeader {
                tab_idx: dragging_idx
            })) if *dragging_idx == tab_idx
        );

        Element::new(
            font,
            ElementContent::Text(format!("  {}", group.to_uppercase())),
        )
        .display(DisplayType::Block)
        .vertical_align(VerticalAlign::Top)
        .item_type(UIItemType::TabBar(TabBarItem::GroupHeader { tab_idx }))
        .line_height(Some(1.15))
        .min_width(Some(Dimension::Pixels(
            (tab_bar_width - horizontal_padding).max(0.),
        )))
        .max_width(Some(Dimension::Pixels(tab_bar_width)))
        .margin(BoxDimension {
            left: Dimension::Pixels(0.),
            right: Dimension::Pixels(0.),
            top: Dimension::Pixels(metrics.cell_size.height as f32 * 0.45),
            bottom: Dimension::Pixels(metrics.cell_size.height as f32 * 0.1),
        })
        .padding(BoxDimension {
            left: Dimension::Cells(0.35),
            right: Dimension::Cells(0.5),
            top: Dimension::Cells(0.1),
            bottom: Dimension::Cells(0.25),
        })
        .border(BoxDimension {
            left: Dimension::Pixels(0.),
            right: Dimension::Pixels(0.),
            top: Dimension::Pixels(0.),
            bottom: Dimension::Pixels(1.),
        })
        .colors(ElementColors {
            border,
            bg: if dragging {
                colors.inactive_tab_hover().bg_color.to_linear().into()
            } else {
                InheritableColor::Inherited
            },
            text: colors.active_tab().fg_color.to_linear().into(),
        })
        .hover_colors(Some(ElementColors {
            border,
            bg: colors.inactive_tab_hover().bg_color.to_linear().into(),
            text: bar_colors.text.clone(),
        }))
    }

    /// Compute the bar background colors based on focus state.
    fn tab_bar_colors(&self) -> ElementColors {
        ElementColors {
            border: BorderColor::default(),
            bg: if self.focused.is_some() {
                self.config.window_frame.active_titlebar_bg
            } else {
                self.config.window_frame.inactive_titlebar_bg
            }
            .to_linear()
            .into(),
            text: if self.focused.is_some() {
                self.config.window_frame.active_titlebar_fg
            } else {
                self.config.window_frame.inactive_titlebar_fg
            }
            .to_linear()
            .into(),
        }
    }

    /// Convert a TabEntry into an Element, used for both horizontal and vertical tab bars.
    fn tab_item_to_element(
        &self,
        item: &TabEntry,
        font: &Rc<LoadedFont>,
        metrics: &RenderMetrics,
        palette: &ColorPalette,
        colors: &TabBarColors,
        bar_colors: &ElementColors,
        _vertical: bool,
    ) -> Element {
        let element = Element::with_line(font, &item.title, palette);

        let bg_color = item
            .title
            .get_cell(0)
            .and_then(|c| match c.attrs().background() {
                ColorAttribute::Default => None,
                col => Some(palette.resolve_bg(col)),
            });
        let fg_color = item
            .title
            .get_cell(0)
            .and_then(|c| match c.attrs().foreground() {
                ColorAttribute::Default => None,
                col => Some(palette.resolve_fg(col)),
            });

        let new_tab = colors.new_tab();
        let new_tab_hover = colors.new_tab_hover();
        let active_tab = colors.active_tab();

        // While a tab is being click-dragged, give it a "lifted" look by
        // shifting its background lightness until the mouse is released.
        let dragging_tab_idx = self.dragging.as_ref().and_then(|(d, _)| match d.item_type {
            UIItemType::TabBar(TabBarItem::Tab { tab_idx, .. }) => Some(tab_idx),
            _ => None,
        });
        let is_dragging = matches!(item.item, TabBarItem::Tab { tab_idx, .. } if Some(tab_idx) == dragging_tab_idx);
        let drag_bg = |c: SrgbaTuple| -> SrgbaTuple {
            if is_dragging {
                // Orange (#FFA500) while the tab is being dragged.
                SrgbaTuple(1.0, 0.647, 0.0, 1.0)
            } else {
                c
            }
        };

        match item.item {
            TabBarItem::RightStatus
            | TabBarItem::LeftStatus
            | TabBarItem::None
            | TabBarItem::GroupHeader { .. } => element
                .item_type(UIItemType::TabBar(TabBarItem::None))
                .line_height(Some(1.75))
                .margin(BoxDimension {
                    left: Dimension::Cells(0.),
                    right: Dimension::Cells(0.),
                    top: Dimension::Cells(0.0),
                    bottom: Dimension::Cells(0.),
                })
                .padding(BoxDimension {
                    left: Dimension::Cells(0.5),
                    right: Dimension::Cells(0.),
                    top: Dimension::Cells(0.),
                    bottom: Dimension::Cells(0.),
                })
                .border(BoxDimension::new(Dimension::Pixels(0.)))
                .colors(bar_colors.clone()),
            TabBarItem::NewTabButton | TabBarItem::NewGroupButton { .. } => {
                let poly = match item.item {
                    TabBarItem::NewTabButton => PLUS_BUTTON,
                    TabBarItem::NewGroupButton { .. } => CATEGORY_BUTTON,
                    _ => unreachable!(),
                };
                Element::new(
                    font,
                    ElementContent::Poly {
                        line_width: metrics.underline_height.max(2),
                        poly: SizedPoly {
                            poly,
                            width: Dimension::Pixels(metrics.cell_size.height as f32 / 2.),
                            height: Dimension::Pixels(metrics.cell_size.height as f32 / 2.),
                        },
                    },
                )
                .vertical_align(VerticalAlign::Middle)
                .item_type(UIItemType::TabBar(item.item.clone()))
                .margin(BoxDimension {
                    left: Dimension::Cells(0.5),
                    right: Dimension::Cells(0.),
                    top: Dimension::Cells(0.2),
                    bottom: Dimension::Cells(0.),
                })
                .padding(BoxDimension {
                    left: Dimension::Cells(0.5),
                    right: Dimension::Cells(0.5),
                    top: Dimension::Cells(0.2),
                    bottom: Dimension::Cells(0.25),
                })
                .border(BoxDimension::new(Dimension::Pixels(1.)))
                .colors(ElementColors {
                    border: BorderColor::default(),
                    bg: new_tab.bg_color.to_linear().into(),
                    text: new_tab.fg_color.to_linear().into(),
                })
                .hover_colors(Some(ElementColors {
                    border: BorderColor::default(),
                    bg: new_tab_hover.bg_color.to_linear().into(),
                    text: new_tab_hover.fg_color.to_linear().into(),
                }))
            }
            TabBarItem::Tab { active, .. } if active => element
                .vertical_align(VerticalAlign::Bottom)
                .item_type(UIItemType::TabBar(item.item.clone()))
                .margin(BoxDimension {
                    left: Dimension::Cells(0.),
                    right: Dimension::Cells(0.),
                    top: Dimension::Cells(0.2),
                    bottom: Dimension::Cells(0.),
                })
                .padding(BoxDimension {
                    left: Dimension::Cells(0.5),
                    right: Dimension::Cells(0.5),
                    top: Dimension::Cells(0.2),
                    bottom: Dimension::Cells(0.25),
                })
                .border(BoxDimension::new(Dimension::Pixels(1.)))
                .border_corners(Some(Corners {
                    top_left: SizedPoly {
                        width: Dimension::Cells(0.5),
                        height: Dimension::Cells(0.5),
                        poly: TOP_LEFT_ROUNDED_CORNER,
                    },
                    top_right: SizedPoly {
                        width: Dimension::Cells(0.5),
                        height: Dimension::Cells(0.5),
                        poly: TOP_RIGHT_ROUNDED_CORNER,
                    },
                    bottom_left: SizedPoly::none(),
                    bottom_right: SizedPoly::none(),
                }))
                .colors(ElementColors {
                    border: BorderColor::new(
                        drag_bg(bg_color.unwrap_or_else(|| active_tab.bg_color.into())).to_linear(),
                    ),
                    bg: drag_bg(bg_color.unwrap_or_else(|| active_tab.bg_color.into()))
                        .to_linear()
                        .into(),
                    text: fg_color
                        .unwrap_or_else(|| active_tab.fg_color.into())
                        .to_linear()
                        .into(),
                }),
            TabBarItem::Tab { .. } => element
                .vertical_align(VerticalAlign::Bottom)
                .item_type(UIItemType::TabBar(item.item.clone()))
                .margin(BoxDimension {
                    left: Dimension::Cells(0.),
                    right: Dimension::Cells(0.),
                    top: Dimension::Cells(0.2),
                    bottom: Dimension::Cells(0.),
                })
                .padding(BoxDimension {
                    left: Dimension::Cells(0.5),
                    right: Dimension::Cells(0.5),
                    top: Dimension::Cells(0.2),
                    bottom: Dimension::Cells(0.25),
                })
                .border(BoxDimension::new(Dimension::Pixels(1.)))
                .border_corners(Some(Corners {
                    top_left: SizedPoly {
                        width: Dimension::Cells(0.5),
                        height: Dimension::Cells(0.5),
                        poly: TOP_LEFT_ROUNDED_CORNER,
                    },
                    top_right: SizedPoly {
                        width: Dimension::Cells(0.5),
                        height: Dimension::Cells(0.5),
                        poly: TOP_RIGHT_ROUNDED_CORNER,
                    },
                    bottom_left: SizedPoly {
                        width: Dimension::Cells(0.),
                        height: Dimension::Cells(0.33),
                        poly: &[],
                    },
                    bottom_right: SizedPoly {
                        width: Dimension::Cells(0.),
                        height: Dimension::Cells(0.33),
                        poly: &[],
                    },
                }))
                .colors({
                    let inactive_tab = colors.inactive_tab();
                    let bg = drag_bg(bg_color.unwrap_or_else(|| inactive_tab.bg_color.into()))
                        .to_linear();
                    let edge = colors.inactive_tab_edge().to_linear();
                    ElementColors {
                        border: BorderColor {
                            left: bg,
                            right: edge,
                            top: bg,
                            bottom: bg,
                        },
                        bg: bg.into(),
                        text: fg_color
                            .unwrap_or_else(|| inactive_tab.fg_color.into())
                            .to_linear()
                            .into(),
                    }
                })
                .hover_colors({
                    let inactive_tab_hover = colors.inactive_tab_hover();
                    Some(ElementColors {
                        border: BorderColor::new(
                            bg_color
                                .unwrap_or_else(|| inactive_tab_hover.bg_color.into())
                                .to_linear(),
                        ),
                        bg: bg_color
                            .unwrap_or_else(|| inactive_tab_hover.bg_color.into())
                            .to_linear()
                            .into(),
                        text: fg_color
                            .unwrap_or_else(|| inactive_tab_hover.fg_color.into())
                            .to_linear()
                            .into(),
                    })
                }),
            TabBarItem::WindowButton(button) => window_button_element(
                button,
                self.window_state.contains(window::WindowState::MAXIMIZED),
                font,
                metrics,
                &self.config,
            ),
        }
    }

    pub fn paint_fancy_tab_bar(&self) -> anyhow::Result<Vec<UIItem>> {
        let computed = self.fancy_tab_bar.as_ref().ok_or_else(|| {
            anyhow::anyhow!("paint_fancy_tab_bar called but fancy_tab_bar is None")
        })?;
        let ui_items = computed.ui_items();

        let gl_state = self.render_state.as_ref().unwrap();
        self.render_element(&computed, gl_state, None)?;

        Ok(ui_items)
    }
}

fn make_x_button(
    font: &Rc<LoadedFont>,
    metrics: &RenderMetrics,
    colors: &TabBarColors,
    tab_idx: usize,
    active: bool,
) -> Element {
    Element::new(
        font,
        ElementContent::Poly {
            line_width: metrics.underline_height.max(2),
            poly: SizedPoly {
                poly: X_BUTTON,
                width: Dimension::Pixels(metrics.cell_size.height as f32 / 2.),
                height: Dimension::Pixels(metrics.cell_size.height as f32 / 2.),
            },
        },
    )
    // Ensure that we draw our background over the
    // top of the rest of the tab contents
    .zindex(1)
    .vertical_align(VerticalAlign::Middle)
    .float(Float::Right)
    .item_type(UIItemType::CloseTab(tab_idx))
    .hover_colors({
        let inactive_tab_hover = colors.inactive_tab_hover();
        let active_tab = colors.active_tab();

        Some(ElementColors {
            border: BorderColor::default(),
            bg: (if active {
                inactive_tab_hover.bg_color
            } else {
                active_tab.bg_color
            })
            .to_linear()
            .into(),
            text: (if active {
                inactive_tab_hover.fg_color
            } else {
                active_tab.fg_color
            })
            .to_linear()
            .into(),
        })
    })
    .padding(BoxDimension {
        left: Dimension::Cells(0.25),
        right: Dimension::Cells(0.25),
        top: Dimension::Cells(0.25),
        bottom: Dimension::Cells(0.25),
    })
    .margin(BoxDimension {
        left: Dimension::Cells(0.5),
        right: Dimension::Cells(0.),
        top: Dimension::Cells(0.),
        bottom: Dimension::Cells(0.),
    })
}
