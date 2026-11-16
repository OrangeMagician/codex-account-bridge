package config

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

// Stored separately so older CAB clients can continue managing the same accounts.
type APISettings struct {
	Account string `json:"account"`
	Home    string `json:"home"`
	Key     string `json:"key"`
}

func ReadAPISettings(paths Paths) (APISettings, error) {
	var settings APISettings
	path := filepath.Join(paths.ConfigDir, "local-api.json")
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return settings, nil
	}
	if err != nil {
		return settings, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return settings, errors.New("unsafe local API settings file")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return settings, err
	}
	if err = json.Unmarshal(data, &settings); err != nil {
		return APISettings{}, errors.New("invalid local API settings")
	}
	key, err := hex.DecodeString(settings.Key)
	if err != nil || len(key) != 32 || settings.Home == "" || settings.Account == "" {
		return APISettings{}, errors.New("incomplete local API settings")
	}
	return settings, nil
}

func SelectAPIAccount(paths Paths, name string) error {
	_, err := ReadLocked(paths, func(cfg Config) error {
		account, ok := cfg.Find(name)
		if !ok {
			return errors.New("choose a registered API account")
		}
		settings, err := ReadAPISettings(paths)
		if err != nil {
			return err
		}
		if settings.Key == "" {
			var key [32]byte
			if _, err := rand.Read(key[:]); err != nil {
				return err
			}
			settings.Key = hex.EncodeToString(key[:])
		}
		settings.Account, settings.Home = account.Name, account.Home
		data, err := json.Marshal(settings)
		if err != nil {
			return err
		}
		return writeAtomic(paths.ConfigDir, filepath.Join(paths.ConfigDir, "local-api.json"), data)
	})
	return err
}
