package model

// Batch represents a minibatch of features and labels.
type Batch struct {
	Inputs [][]float64
	Labels []int
}

// Model defines the minimal training functionality required by the demo.
type Model interface {
	TrainStep(batch Batch) float64
}
