package strategies

import (
	"context"

	"github.com/puravida-software/bondi/server/deployment/models"
)

type Strategy interface {
	Deploy(ctx context.Context, input *models.DeployInput) error
}
