FROM mcr.microsoft.com/devcontainers/base:ubuntu26.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install the full lint/format toolchain directly in the image so the
# devcontainer does not depend on feature-specific shell initialization.
RUN apt-get update \
		&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
			ca-certificates \
			curl \
			make \
			python3 \
			python3-pip \
			xz-utils \
		&& python3 -m pip install --break-system-packages --no-cache-dir \
			'ansible-core>=2.21' \
			ansible-lint \
			yamllint \
		&& apt-get clean \
		&& rm -rf /var/lib/apt/lists/*

USER vscode

ENV PATH="/home/vscode/.nix-profile/bin:/home/vscode/.local/bin:${PATH}"

RUN curl -fsSL https://nixos.org/nix/install | sh -s -- --no-daemon --yes \
		&& mkdir -p /home/vscode/.config/nix \
		&& printf 'experimental-features = nix-command flakes\n' > /home/vscode/.config/nix/nix.conf