package ui

import (
	. "go.hasen.dev/shirei"
	. "go.hasen.dev/shirei/widgets"
)

type workstationButtonStrength uint8

const (
	workstationButtonCommand workstationButtonStrength = iota
	workstationButtonToolbar
)

// RaisedFrame builds the directional workstation bevel used by elevated
// machinery. outer controls placement/size; face controls the content layout.
func RaisedFrame(theme Theme, outer, face AttrSet, fn func()) ContainerId {
	return Container(AttrsWith(outer,
		BackgroundVec(theme.DarkShadow), Pad4(0, 1, 1, 0), NoAnimate,
	), func() {
		Container(Attrs(Grow(1), Expand, BackgroundVec(theme.Light), Pad4(1, 0, 0, 1), NoAnimate), func() {
			Container(AttrsWith(face,
				Grow(1), Expand, BackgroundVec(theme.ChromeRaised), Grad(0, 0, -4, 0), NoAnimate,
			), fn)
		})
	})
}

// InsetFrame reverses RaisedFrame's edge order so the content reads as a
// recessed well rather than an elevated control.
func InsetFrame(theme Theme, outer, well AttrSet, fn func()) ContainerId {
	return Container(AttrsWith(outer,
		BackgroundVec(theme.Light), Pad4(0, 1, 1, 0), NoAnimate,
	), func() {
		Container(Attrs(Grow(1), Expand, BackgroundVec(theme.DarkShadow), Pad4(1, 0, 0, 1), NoAnimate), func() {
			Container(AttrsWith(well,
				Grow(1), Expand, BackgroundVec(theme.ChromeInset), NoAnimate,
			), fn)
		})
	})
}

// PaperWell seats the flat document surface inside a restrained inset edge.
func PaperWell(theme Theme, outer, paper AttrSet, fn func()) ContainerId {
	return InsetFrame(theme, outer, AttrsWith(paper, BackgroundVec(theme.Paper)), fn)
}

// ChromeBar paints a shallow vertical material gradient without elevating the
// entire region. Directional separators should be composed explicitly.
func ChromeBar(theme Theme, attrs AttrSet, fn func()) ContainerId {
	return Container(AttrsWith(attrs,
		BackgroundVec(theme.Chrome), Grad(0, 0, -3, 0), NoAnimate,
	), fn)
}

type dividerAxis uint8

const (
	dividerVertical dividerAxis = iota
	dividerHorizontal
)

// EtchedDivider is a two-pixel dark/light seam. It communicates a structural
// boundary without creating a card or drop shadow.
func EtchedDivider(theme Theme, axis dividerAxis) ContainerId {
	attrs := Attrs(Row, FixWidth(2), Expand, NoAnimate)
	edge := Attrs(FixWidth(1), Expand, BackgroundVec(theme.DarkShadow), NoAnimate)
	light := Attrs(FixWidth(1), Expand, BackgroundVec(theme.Light), NoAnimate)
	if axis == dividerHorizontal {
		attrs = Attrs(FixHeight(2), Expand, NoAnimate)
		edge = Attrs(FixHeight(1), Expand, BackgroundVec(theme.DarkShadow), NoAnimate)
		light = Attrs(FixHeight(1), Expand, BackgroundVec(theme.Light), NoAnimate)
	}
	return Container(attrs, func() {
		Element(edge)
		Element(light)
	})
}

// WorkstationButton is the clearly raised command-button treatment used for
// affirmative dialog and transient-bar actions.
func WorkstationButton(theme Theme, label string, enabled bool) bool {
	clicked, _ := workstationButton(theme, label, enabled, workstationButtonCommand)
	return clicked
}

// WorkstationToolButton is the lighter toolbar treatment: nearly flat at rest,
// subtly raised on hover, and recessed while pressed.
func WorkstationToolButton(theme Theme, label string, enabled bool) bool {
	clicked, _ := workstationButton(theme, label, enabled, workstationButtonToolbar)
	return clicked
}

func workstationButton(theme Theme, label string, enabled bool, strength workstationButtonStrength) (bool, ContainerId) {
	var clicked bool
	host := Container(Attrs(), func() {
		state := ProcessButtonEvents(!enabled)
		clicked = state.Clicked
		skin := theme
		if strength == workstationButtonToolbar && !state.Hovered && !state.Active {
			skin.Light[3] = 0
			skin.DarkShadow[3] = 0
			skin.ChromeRaised = skin.Chrome
		}
		if !enabled {
			skin.ChromeRaised = theme.Chrome
			skin.Light[3] *= 0.45
			skin.DarkShadow[3] *= 0.35
		}
		face := Attrs(Row, CrossMid, Center, FixHeight(24), Pad2(0, 8), Corners(1))
		outer := Attrs(FixHeight(26), Corners(2))
		if strength == workstationButtonCommand {
			face = Attrs(Row, CrossMid, Center, FixHeight(26), Pad2(0, 11), Corners(2))
			outer = Attrs(FixHeight(28), Corners(2))
		}
		paint := RaisedFrame
		if state.Active {
			paint = InsetFrame
		}
		paint(skin, outer, face, func() {
			if state.Hovered && enabled && !state.Active {
				ModAttrs(BackgroundVec(theme.Highlight), Grad(0, 0, -3, 0))
			}
			color := theme.Ink
			if !enabled {
				color = theme.Muted
			}
			Label(label, FontSize(11), TextColorVec(color))
		})
	})
	return clicked, host
}

// WorkstationSegmentedControl renders property-sheet-style tabs. The selected
// segment is flat and open at the bottom so it joins the sidebar content;
// inactive segments retain a shallow raised bevel.
func WorkstationSegmentedControl[T comparable](theme Theme, target *T, segments ...SegmentedCell[T]) bool {
	return workstationSegmentedControl(theme, target, nil, segments...)
}

func workstationSegmentedControl[T comparable](theme Theme, target *T, cellIDs map[T]ContainerId, segments ...SegmentedCell[T]) bool {
	changed := false
	Container(Attrs(Row, CrossAlign(AlignEnd), FixHeight(29), NoAnimate), func() {
		for _, segment := range segments {
			segment := segment
			cellID := ContainerWithKey(segment.Value, Attrs(FixHeight(29), MinWidth(76)), func() {
				state := ProcessSegmentEvents(target, segment.Value, false)
				changed = changed || state.BecameSelected
				if state.Selected {
					Container(Attrs(Grow(1), Expand, BackgroundVec(theme.DarkShadow), Pad4(1, 1, 0, 1), NoAnimate), func() {
						Container(Attrs(Grow(1), Expand, Center, BackgroundVec(theme.Sidebar), NoAnimate), func() {
							Label(segment.Label, FontSize(11), FontWeight(WeightBold), TextColorVec(theme.Ink))
						})
					})
					return
				}
				skin := theme
				if state.Active {
					InsetFrame(skin, Attrs(Grow(1), Expand), Attrs(Center), func() {
						Label(segment.Label, FontSize(11), TextColorVec(theme.Ink))
					})
					return
				}
				RaisedFrame(skin, Attrs(Grow(1), Expand), Attrs(Center), func() {
					if state.Hovered {
						ModAttrs(BackgroundVec(theme.Highlight))
					}
					Label(segment.Label, FontSize(11), TextColorVec(theme.Ink))
				})
			})
			if cellIDs != nil {
				cellIDs[segment.Value] = cellID
			}
		}
	})
	return changed
}

// WorkstationRow keeps idle rows flat while giving hover and selection the
// same restrained steel hierarchy used throughout the shell.
func WorkstationRow(theme Theme, attrs AttrSet, selected, disabled bool, fn func()) ButtonState {
	var state ButtonState
	Container(attrs, func() {
		state = ProcessButtonEvents(disabled)
		switch {
		case selected:
			ModAttrs(BackgroundVec(theme.Selection), Grad(0, 0, -6, 0), BorderWidth(1), BorderColorVec(theme.SelectionShadow))
		case state.Hovered && !disabled:
			ModAttrs(BackgroundVec(theme.Highlight), Grad(0, 0, -2, 0))
		}
		fn()
	})
	return state
}

// workstationScrollBar uses Shirei's public custom scrollbar painter. The
// track is recessed and the thumb is raised, while scrolling behavior remains
// entirely framework-owned.
func workstationScrollBar() ContainerId {
	theme := DefaultTheme()
	return ScrollBarExt(ScrollBarAttrs{
		TrackWidth:     13,
		TrackPad:       2,
		TrackBG:        theme.ChromeInset,
		ThumbMinHeight: 22,
		Thumb: func(size Vec2) {
			RaisedFrame(theme,
				Attrs(FixSizeVec(size)),
				Attrs(FixSizeVec(Vec2{max(float32(1), size[0]-2), max(float32(1), size[1]-2)}), Corners(1)),
				func() {},
			)
		},
	})
}
