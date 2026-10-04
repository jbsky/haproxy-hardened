// HAProxy hardened init -- remplace le shell d'entree et le healthcheck curl.
// Binaire statique, aucune dependance au shell.
//
// Usage:
//
//	init --healthcheck      healthcheck Docker (exit 0/1)
//	init --setup-dirs       cree les repertoires runtime (au build, FROM scratch)
//	init [CMD [ARGS...]]    entrypoint : valide la configuration, puis exec CMD
//
// Les arguments peuvent arriver SANS le nom du binaire (VyOS passe
// `arguments "-W -f /usr/local/etc/haproxy/haproxy.cfg"`, qui remplace le CMD) :
// un premier argument qui commence par « - » recoit « haproxy » devant.
package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

const (
	haproxyUID    = 4430
	haproxyGID    = 4430
	haproxyBin    = "/usr/sbin/haproxy"
	defaultConf   = "/usr/local/etc/haproxy/haproxy.cfg"
	defaultHealth = "http://127.0.0.1:8405/healthz"
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--healthcheck":
			os.Exit(healthcheck())
		case "--setup-dirs":
			if err := setupDirs(); err != nil {
				fmt.Fprintf(os.Stderr, "[init][ERROR] setup-dirs: %v\n", err)
				os.Exit(1)
			}
			return
		}
	}
	if err := entrypoint(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "[init][ERROR] %v\n", err)
		os.Exit(1)
	}
}

// ---------------------------------------------------------------------------
// Setup directories -- appele au build, dans le stage FROM scratch.
// ---------------------------------------------------------------------------

func setupDirs() error {
	dirs := []struct {
		path string
		mode os.FileMode
		uid  int
		gid  int
	}{
		{"/var", 0755, 0, 0},
		{"/var/lib", 0755, 0, 0},
		{"/var/lib/haproxy", 0750, haproxyUID, haproxyGID},
		{"/run", 0755, 0, 0},
		{"/run/haproxy", 0750, haproxyUID, haproxyGID},
		{"/tmp", 01777, 0, 0},
	}
	for _, d := range dirs {
		fmt.Printf("[init] mkdir %s (mode=%04o uid=%d gid=%d)\n", d.path, d.mode, d.uid, d.gid)
		if err := os.MkdirAll(d.path, d.mode); err != nil {
			return fmt.Errorf("mkdir %s: %w", d.path, err)
		}
		if err := os.Chmod(d.path, d.mode); err != nil {
			return fmt.Errorf("chmod %s: %w", d.path, err)
		}
		if err := os.Chown(d.path, d.uid, d.gid); err != nil {
			return fmt.Errorf("chown %s: %w", d.path, err)
		}
	}
	fmt.Println("[init] setup-dirs complete")
	return nil
}

// ---------------------------------------------------------------------------
// Healthcheck : GET sur un monitor-uri de HAProxy (protocole du service, pas
// un simple connect TCP). La configuration doit l'exposer ; celle livree dans
// l'image le fait sur 127.0.0.1:8405. Autre URL : HAPROXY_HEALTH_URL.
// ---------------------------------------------------------------------------

func healthcheck() int {
	url := env("HAPROXY_HEALTH_URL", defaultHealth)
	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			DialContext: (&net.Dialer{Timeout: 2 * time.Second}).DialContext,
			Proxy:       nil,
		},
	}
	resp, err := client.Get(url)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[healthcheck] GET %s failed: %v\n", url, err)
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 400 {
		fmt.Fprintf(os.Stderr, "[healthcheck] GET %s returned %d\n", url, resp.StatusCode)
		return 1
	}
	return 0
}

// ---------------------------------------------------------------------------
// Entrypoint : valider la configuration, puis exec haproxy
// ---------------------------------------------------------------------------

func entrypoint(args []string) error {
	args = commandLine(args)
	confs := configFiles(args)
	if len(confs) == 0 {
		confs = []string{env("HAPROXY_CONF", defaultConf)}
	}
	for _, c := range confs {
		if !exists(c) {
			return fmt.Errorf("config %s not found -- is the configuration volume mounted?", c)
		}
	}

	// Les sockets et pid (stats socket, master CLI) vont dans /tmp ou /run :
	// en lecture seule, ils doivent etre des tmpfs. Le dire tot, pas au bind.
	for _, d := range []string{"/tmp", "/run/haproxy"} {
		if exists(d) && !writeOK(d) {
			log("WARNING: %s is not writable by uid %d (read-only rootfs without tmpfs?)", d, os.Getuid())
		}
	}

	// Validation (haproxy -c) : une configuration cassee empeche le demarrage
	// au lieu de produire un service a moitie charge.
	check := []string{"-c", "-q"}
	for _, c := range confs {
		check = append(check, "-f", c)
	}
	log("Validating configuration (%s)...", strings.Join(confs, ", "))
	if err := run(haproxyBin, check...); err != nil {
		return fmt.Errorf("haproxy config check failed: %w", err)
	}
	log("Configuration OK")

	log("Starting HAProxy: %s", strings.Join(args, " "))
	return execCmd(args)
}

// commandLine complete les arguments bruts : sans commande, le CMD de l'image
// s'applique deja (Docker) ; un premier argument en « - » recoit « haproxy ».
func commandLine(args []string) []string {
	if len(args) == 0 {
		return []string{"haproxy", "-W", "-db", "-f", defaultConf}
	}
	if strings.HasPrefix(args[0], "-") {
		return append([]string{"haproxy"}, args...)
	}
	return args
}

// configFiles extrait les chemins passes par -f (plusieurs -f permis).
func configFiles(args []string) []string {
	var out []string
	for i := 0; i < len(args); i++ {
		if args[i] == "-f" && i+1 < len(args) {
			out = append(out, args[i+1])
			i++
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// Helpers -- vocabulaire commun du parc : env, exists, writeOK
// ---------------------------------------------------------------------------

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// writeOK dit si un repertoire accepte reellement une ecriture. mkdir + chmod
// + chown peuvent tous reussir sur un point de montage en lecture seule :
// seule une ecriture le prouve.
func writeOK(dir string) bool {
	tmp, err := os.CreateTemp(dir, ".write-test-*")
	if err != nil {
		return false
	}
	name := tmp.Name()
	tmp.Close()
	os.Remove(name)
	return true
}

func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func execCmd(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("no command specified")
	}
	bin, err := exec.LookPath(args[0])
	if err != nil {
		return fmt.Errorf("command not found: %s", args[0])
	}
	return syscall.Exec(bin, args, os.Environ())
}

func log(format string, a ...any) {
	fmt.Printf("[init] "+format+"\n", a...)
}
