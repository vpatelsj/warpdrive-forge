package model

import (
	"math"
	"math/rand"
)

// SimpleCNN is a tiny linear classifier with softmax cross-entropy.
type SimpleCNN struct {
	numClasses int
	inputSize  int
	weights    []float64
	bias       []float64
	lr         float64
}

// NewSimpleCNN constructs the model with random initialization.
func NewSimpleCNN(numClasses, inputSize int, lr float64, seed int64) *SimpleCNN {
	if numClasses <= 0 {
		numClasses = 10
	}
	if inputSize <= 0 {
		inputSize = 64
	}
	if lr <= 0 {
		lr = 0.01
	}
	rng := rand.New(rand.NewSource(seed))
	weights := make([]float64, numClasses*inputSize)
	for i := range weights {
		weights[i] = (rng.Float64()*2 - 1) * 0.01
	}
	bias := make([]float64, numClasses)
	return &SimpleCNN{
		numClasses: numClasses,
		inputSize:  inputSize,
		weights:    weights,
		bias:       bias,
		lr:         lr,
	}
}

// TrainStep executes one SGD step and returns average loss.
func (m *SimpleCNN) TrainStep(batch Batch) float64 {
	if len(batch.Inputs) == 0 {
		return 0
	}
	totalLoss := 0.0
	for i, input := range batch.Inputs {
		if len(input) != m.inputSize {
			continue
		}
		label := batch.Labels[i]
		if label < 0 || label >= m.numClasses {
			label = label % m.numClasses
			if label < 0 {
				label += m.numClasses
			}
		}
		logits := make([]float64, m.numClasses)
		for c := 0; c < m.numClasses; c++ {
			sum := m.bias[c]
			wStart := c * m.inputSize
			for j := 0; j < m.inputSize; j++ {
				sum += m.weights[wStart+j] * input[j]
			}
			logits[c] = sum
		}
		probs := softmax(logits)
		totalLoss += -math.Log(math.Max(probs[label], 1e-9))

		probs[label] -= 1
		for c := 0; c < m.numClasses; c++ {
			grad := probs[c]
			m.bias[c] -= m.lr * grad
			wStart := c * m.inputSize
			for j := 0; j < m.inputSize; j++ {
				m.weights[wStart+j] -= m.lr * grad * input[j]
			}
		}
	}
	return totalLoss / float64(len(batch.Inputs))
}

func softmax(logits []float64) []float64 {
	maxLogit := logits[0]
	for _, v := range logits {
		if v > maxLogit {
			maxLogit = v
		}
	}
	sum := 0.0
	out := make([]float64, len(logits))
	for i, v := range logits {
		exp := math.Exp(v - maxLogit)
		out[i] = exp
		sum += exp
	}
	inv := 1.0 / sum
	for i := range out {
		out[i] *= inv
	}
	return out
}
