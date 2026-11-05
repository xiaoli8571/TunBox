// Package bridge — profile native validation and outbound projection.
//
// FlClash parity (upstream be84736605527034689c95bf27828ff27d912c5e):
//   - lib/models/profile.dart Profile.saveFile: bytes -> temp file -> validate
//     -> copy temp to profiles/<id>.yaml (no anchor expansion, raw copy).
//   - lib/core/controller.dart validateProfile(path, ageSecretKey): in-place
//     age decrypt, then validateConfig, then convertProxies fallback.
//   - core/config.go handleValidateConfig = readRawConfig only (unmarshal).
//   - core/profile_base.go handleGetProfileOutbounds:52 projects name/type
//     only, for the host's shadow node list.
//
// Errors keep the original type/message (no Chinese rewrite).
package bridge

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/metacubex/mihomo/common/convert"
	"github.com/metacubex/mihomo/component/age"
	"github.com/metacubex/mihomo/config"
	goyaml "go.yaml.in/yaml/v3"
)

// ErrAgeSecretKeyRequired mirrors FlClash AgeSecretKeyRequiredException:
// the input carries the age armor header but no key was supplied.
var ErrAgeSecretKeyRequired = errors.New("AgeSecretKeyRequired")

// unmarshalProfileRawConfig is FlClash core's unmarshalRawConfig wrapper
// (core/short_id.go): mihomo decodes an unquoted REALITY short-id as a YAML
// number (0123 -> 83); retagging the scalar restores the literal id.
func unmarshalProfileRawConfig(buf []byte) (*config.RawConfig, error) {
	if !bytes.Contains(buf, []byte("short-id")) {
		return config.UnmarshalRawConfig(buf)
	}
	var document goyaml.Node
	if err := goyaml.Unmarshal(buf, &document); err != nil {
		return config.UnmarshalRawConfig(buf)
	}
	if !retagProfileShortIDs(&document) {
		return config.UnmarshalRawConfig(buf)
	}
	rawConfig := config.DefaultRawConfig()
	if err := document.Decode(rawConfig); err != nil {
		return nil, err
	}
	return rawConfig, nil
}

func retagProfileShortIDs(node *goyaml.Node) bool {
	retagged := false
	if node.Kind == goyaml.MappingNode {
		for i := 0; i+1 < len(node.Content); i += 2 {
			if node.Content[i].Value == "short-id" {
				retagged = retagProfileNumber(node.Content[i+1]) || retagged
			}
		}
	}
	for _, child := range node.Content {
		retagged = retagProfileShortIDs(child) || retagged
	}
	return retagged
}

func retagProfileNumber(node *goyaml.Node) bool {
	switch node.Kind {
	case goyaml.ScalarNode:
		if node.Style == 0 && (node.Tag == "!!int" || node.Tag == "!!float") {
			node.Tag = "!!str"
			return true
		}
	case goyaml.SequenceNode:
		retagged := false
		for _, item := range node.Content {
			retagged = retagProfileNumber(item) || retagged
		}
		return retagged
	}
	return false
}

// validateConfigBytes is FlClash handleValidateConfig (core/config.go:83):
// existence + native parse only, no rule/geo side effects.
func validateConfigBytes(buf []byte) error {
	_, err := unmarshalProfileRawConfig(buf)
	return err
}

// ValidateProfile implements FlClash Profile.saveFile + controller
// validateProfile natively:
//
//	bytes -> temp file -> age decrypt (if armor) -> validateConfig ->
//	if invalid, convert.ConvertsV2Ray -> if non-empty, write {'proxies':...}
//	YAML to temp and revalidate -> if still failing return the FIRST issue ->
//	on success copy the final bytes verbatim to profilePath.
//
// The copy is byte-verbatim (anchors are NOT expanded): FlClash copies the
// temp file, it does not Run PrepareProfile. Errors keep the original
// type/message; an armor header with empty key returns
// ErrAgeSecretKeyRequired (FlClash AgeSecretKeyRequiredException).
func ValidateProfile(content []byte, ageSecretKey string, profilePath string) error {
	tmp, err := os.CreateTemp("", "profile-validate-*.yaml")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)

	if _, err := tmp.Write(content); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}

	// Age: armor header + empty key -> AgeSecretKeyRequired (original).
	if bytes.HasPrefix(content, []byte(age.FileHeader)) {
		if strings.TrimSpace(ageSecretKey) == "" {
			return ErrAgeSecretKeyRequired
		}
		plaintext, decErr := age.DecryptBytes(content, ageSecretKey)
		if decErr != nil {
			return decErr
		}
		content = plaintext
		if err := os.WriteFile(tmpName, content, 0o600); err != nil {
			return err
		}
	}

	if issue := validateConfigBytes(content); issue == nil {
		return copyProfileBytes(tmpName, profilePath)
	} else {
		firstIssue := issue
		proxies, convErr := convert.ConvertsV2Ray(content)
		if convErr != nil || len(proxies) == 0 {
			return firstIssue
		}
		converted, yamlErr := goyaml.Marshal(map[string]any{"proxies": proxies})
		if yamlErr != nil {
			return firstIssue
		}
		if err := os.WriteFile(tmpName, converted, 0o600); err != nil {
			return err
		}
		if validateConfigBytes(converted) != nil {
			return firstIssue
		}
		return copyProfileBytes(tmpName, profilePath)
	}
}

func copyProfileBytes(tmpName, profilePath string) error {
	if err := os.MkdirAll(filepath.Dir(profilePath), 0o755); err != nil {
		return err
	}
	data, err := os.ReadFile(tmpName)
	if err != nil {
		return err
	}
	return os.WriteFile(profilePath, data, 0o600)
}

// ProfileOutbound is the name/type projection of one FlClash outbound.
type ProfileOutbound struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

// ProfileOutbounds mirrors FlClash core ProfileOutbounds.
type ProfileOutbounds struct {
	Proxies     []ProfileOutbound `json:"proxies"`
	ProxyGroups []ProfileOutbound `json:"proxy-groups"`
}

// GetProfileOutbounds aligns with FlClash handleGetProfileOutbounds
// (core/profile_base.go:52): read the profile file, parse with the same
// short-id aware reader, project name/type only. The ArkTS CoreNodeBridge
// maps these into shadow ProxyNodes (name identical to the kernel's).
func GetProfileOutbounds(path string) (*ProfileOutbounds, error) {
	buf, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	raw, err := unmarshalProfileRawConfig(buf)
	if err != nil {
		return nil, err
	}
	return &ProfileOutbounds{
		Proxies:     profileOutboundsOf(raw.Proxy),
		ProxyGroups: profileOutboundsOf(raw.ProxyGroup),
	}, nil
}

func profileOutboundsOf(mappings []map[string]any) []ProfileOutbound {
	outbounds := make([]ProfileOutbound, 0, len(mappings))
	for _, mapping := range mappings {
		name, _ := mapping["name"].(string)
		kind, _ := mapping["type"].(string)
		outbounds = append(outbounds, ProfileOutbound{Name: name, Type: kind})
	}
	return outbounds
}
