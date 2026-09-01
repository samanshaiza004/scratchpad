package ui

import (
	. "go.hasen.dev/shirei"
	. "go.hasen.dev/shirei/widgets"
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
