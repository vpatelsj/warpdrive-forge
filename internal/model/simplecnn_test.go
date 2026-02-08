package model

import "testing"

func TestSimpleCNNTrainStepReducesLoss(t *testing.T) {
	model := NewSimpleCNN(3, 4, 0.1, 1)
	batch := Batch{
		Inputs: [][]float64{
			{0.1, 0.2, 0.3, 0.4},
			{0.4, 0.3, 0.2, 0.1},
		},
		Labels: []int{1, 2},
	}
	loss1 := model.TrainStep(batch)
	loss2 := model.TrainStep(batch)
	if loss2 > loss1 {
		t.Fatalf("expected loss to decrease; loss1=%f loss2=%f", loss1, loss2)
	}
}
