package trainer

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"testing"
)

func TestExtractFeatures(t *testing.T) {
	img := image.NewGray(image.Rect(0, 0, featureGrid, featureGrid))
	for y := 0; y < featureGrid; y++ {
		for x := 0; x < featureGrid; x++ {
			img.SetGray(x, y, color.Gray{Y: uint8((x + y) % 255)})
		}
	}
	buf := &bytes.Buffer{}
	if err := png.Encode(buf, img); err != nil {
		t.Fatalf("encode: %v", err)
	}
	features, err := extractFeatures(buf.Bytes())
	if err != nil {
		t.Fatalf("extractFeatures: %v", err)
	}
	if len(features) != featureSize {
		t.Fatalf("expected %d features, got %d", featureSize, len(features))
	}
	for _, v := range features {
		if v < 0 || v > 1 {
			t.Fatalf("feature out of range: %f", v)
		}
	}
}
