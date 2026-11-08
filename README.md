# Apache Lab Manager

CLI em Bash para cadastrar servidores Ubuntu/Debian, diagnosticar, instalar Apache2 e publicar Virtual Hosts remotamente por meio do Ansible. As operações protegem serviços existentes e não alteram firewall, DNS, HTTPS, K3s, containers ou processos de terceiros.

## Requisitos

- Controladora Linux com Bash 4 ou superior;
- Ansible Core 2.21 (`ansible` e `ansible-playbook`), preferencialmente no `.venv` do projeto;
- servidores Ubuntu acessíveis por SSH;
- autenticação por chave ou outra forma já configurada no OpenSSH.

Em Ubuntu/Debian, instale o Ansible pelos repositórios da distribuição:

```bash
sudo apt update
sudo apt install ansible
```

Quando `.venv/bin/ansible` e `.venv/bin/ansible-playbook` existem, a CLI os utiliza automaticamente. Caso contrário, procura os comandos no `PATH`.

Nenhuma biblioteca Python adicional é exigida pelo projeto. O Ansible requer Python no host remoto, como é habitual em instalações Ubuntu.

## Execução e cadastro

```bash
chmod +x apache-manager.sh
./apache-manager.sh
```

No primeiro uso, a CLI cria `inventory/hosts.yml` com permissão `0600` e oferece o cadastro inicial. Informe alias, endereço SSH, usuário, porta, chave opcional e se o host normalmente usa `become`. O diagnóstico não eleva privilégios; a instalação eleva somente as tarefas que precisam inspecionar processos, instalar pacotes ou gerenciar o serviço.

O inventário real é ignorado pelo Git. `inventory/hosts.example.yml` serve apenas como modelo e usa um endereço reservado para documentação.

## Autenticação SSH

A opção recomendada é configurar `~/.ssh/config` e cadastrar o `Host` como endereço:

```sshconfig
Host dev-lab
    HostName 192.0.2.10
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
```

Também é possível informar o caminho da chave durante o cadastro. A ferramenta armazena somente o caminho, nunca senha ou conteúdo de chave privada. Para chaves protegidas, carregue-as previamente com `ssh-add`.

Teste primeiro o OpenSSH diretamente:

```bash
ssh dev-lab
```

## Diagnóstico

Escolha **1 - Diagnosticar Apache**, selecione um ou vários hosts por número (ou digite `todos`) e confira o relatório separado por servidor. São coletados:

- distribuição e versão do Linux;
- conectividade SSH/Ansible;
- presença e versão do pacote `apache2`;
- estado e habilitação do serviço;
- uso da porta TCP 80 e processo visível;
- resultado de `apache2ctl configtest`;
- Virtual Hosts em `/etc/apache2/sites-enabled`.

Alguns nomes de processos podem ficar ocultos para usuários sem privilégios. Isso é informado normalmente e não justifica elevar privilégios durante esta etapa.

## Instalação segura do Apache

Escolha **2 - Instalar Apache**, selecione os hosts e confirme a lista apresentada. Se o `sudo` remoto exigir senha, responda `s` quando a CLI oferecer `--ask-become-pass`.

Antes de qualquer instalação, cada servidor passa por verificações independentes de conectividade, sistema operacional, privilégios, pacote existente e porta TCP 80. Uma porta ocupada somente é aceita quando o Apache2 já está instalado e o processo é identificado inequivocamente como `apache2`. Qualquer outro caso é bloqueado naquele host, sem parar ou modificar o processo encontrado.

O pacote é instalado com `policy_rc_d=101`, evitando que seu script de instalação inicie o serviço prematuramente. Depois, a configuração passa por `apache2ctl configtest`; somente então o serviço é iniciado e habilitado. Execuções repetidas não reinstalam nem reiniciam um Apache saudável.

## Publicação de site

Escolha **3 - Publicar novo site** e informe domínio, alias opcional, e-mail administrativo opcional, título e porta HTTP (padrão 80). Selecione os servidores somente depois desses dados. A CLI mostra domínio, porta, caminhos e hosts antes de pedir confirmação.

O deploy cria `/var/www/DOMINIO/public_html`, `/var/www/DOMINIO/logs` e `/etc/apache2/sites-available/DOMINIO.conf`. O `index.html` demonstrativo usa HTML/CSS local e somente é criado quando ainda não existe. Repetir o deploy não apaga uma personalização posterior.

Virtual Hosts conflitantes bloqueiam o host. Uma configuração de destino existente também é bloqueada, salvo quando o usuário autoriza explicitamente sua atualização. Alterar um domínio existente para outra porta exige uma segunda confirmação. O playbook guarda backup, ativa o symlink idempotentemente, executa `configtest` e somente recarrega o Apache quando algo mudou. Falhas de configuração ou HTTP restauram configuração, ativação e `Listen` anteriores.

Portas personalizadas usam um arquivo isolado, como `/etc/apache2/conf-available/apache-lab-listen-8088.conf`; `ports.conf` e `Listen 80` não são removidos ou reescritos. Antes do deploy, a ferramenta inspeciona o socket e regras NAT visíveis via iptables/nftables. Portas ocupadas por terceiros, redirecionadas por Kubernetes/HostPort ou cuja segurança não possa ser determinada são bloqueadas. Um socket identificado como Apache pode ser reutilizado.

Exemplo para evitar as portas 80/443 usadas por K3s/Traefik:

```text
Domínio principal: cardoso.test
Alias de domínio [opcional]:
E-mail administrativo [opcional]:
Título da página demonstrativa: Cardoso Lab
Porta HTTP [80]: 8088
```

A validação HTTP é local no servidor e envia o `Host` correto; portanto, não depende de DNS público. Para validar manualmente, substitua `IP_DO_SERVIDOR`:

```bash
curl -i -H 'Host: cardoso.test' http://IP_DO_SERVIDOR:8088/
curl -i -H 'Host: cardoso.test' \
  http://IP_DO_SERVIDOR:8088/.apache-lab-manager-check
```

Para abrir no navegador antes de configurar DNS, adicione temporariamente no computador cliente:

```text
IP_DO_SERVIDOR cardoso.test
```

Depois acesse `http://cardoso.test:8088`. Essa entrada pertence ao arquivo `hosts` do cliente; a ferramenta não altera DNS.

Para substituir a página, copie seu arquivo mantendo permissão de leitura para o Apache:

```bash
sudo install -o root -g root -m 0644 meu-index.html \
  /var/www/cardoso.test/public_html/index.html
```

### Testar idempotência e rollback

Para verificar idempotência, publique `cardoso.test:8088` duas vezes com os mesmos dados. Na segunda execução, autorize o Virtual Host existente, mas não uma mudança de porta. O resumo do Ansible deve terminar sem alterações e o Apache não deve ser recarregado.

Teste rollback apenas em um host descartável de laboratório: faça backup local de `templates/vhost.conf.j2`, acrescente temporariamente uma diretiva Apache inválida ao template e publique um domínio descartável em uma porta livre. O `configtest` deve falhar antes do reload, e o relatório deve indicar reversão do Virtual Host e do arquivo `Listen`. Restaure imediatamente o template original e confirme no servidor:

```bash
sudo apache2ctl configtest
systemctl is-active apache2
test ! -e /etc/apache2/conf-enabled/apache-lab-listen-PORTA.conf
```

## Teardown seguro

Escolha **5 - Destruir / Remover ambiente Apache**. As três operações executam primeiro uma descoberta somente de leitura, mostram o plano por servidor e exigem a palavra exata `DESTRUIR` antes da fase de aplicação:

1. **Remover um site específico**: desabilita e remove somente o Virtual Host escolhido. O conteúdo em `/var/www/DOMINIO` somente é excluído após uma confirmação separada de perda de dados.
2. **Remover todos os sites gerenciados**: remove somente configurações que contenham o marcador do Apache Lab Manager. Sites desconhecidos e legados não são incluídos automaticamente.
3. **Desinstalar completamente o Apache**: bloqueia a operação diante de Virtual Hosts desconhecidos ou se a simulação do apt indicar remoção de pacotes fora de `apache2`, `apache2-bin`, `apache2-data` e `apache2-utils`. Não executa `autoremove`.

Sites criados por versões anteriores são classificados como legados somente quando a configuração e o arquivo marcador no DocumentRoot comprovam sua origem. Mesmo assim, sua remoção precisa ser autorizada explicitamente. O inventário nunca é apagado.

Para validar uma remoção de site:

```bash
test ! -e /etc/apache2/sites-enabled/cardoso.test.conf
test ! -e /etc/apache2/sites-available/cardoso.test.conf
sudo apache2ctl configtest
sudo apache2ctl -S
systemctl is-active apache2
```

Para validar uma desinstalação:

```bash
dpkg-query -W apache2
systemctl is-active apache2
test -d /var/www
systemctl is-active k3s
```

Teste somente em VM descartável: publique dois sites gerenciados, adicione um Virtual Host de terceiro como sentinela e execute, separadamente, remoção individual, remoção de todos e desinstalação. Repita cada teardown para confirmar idempotência. A sentinela deve ser preservada e deve bloquear a desinstalação completa; K3s, Traefik, n8n e regras de rede devem permanecer inalterados.

## Funcionalidades

Disponíveis nas etapas 1, 2 e 3:

- cadastro persistente, validação e bloqueio de aliases duplicados;
- listagem e seleção de um ou vários servidores;
- teste de conectividade pelo módulo `ansible.builtin.ping`;
- diagnóstico remoto somente de leitura;
- instalação idempotente com proteção contra conflito na porta 80;
- relatório de instalação individual por servidor;
- publicação idempotente de Virtual Hosts com detecção de conflitos e rollback;
- validação HTTP local por `Host` header e relatório por servidor;
- teardown planejado e confirmado de sites gerenciados e pacotes Apache;
- retorno aos menus e tratamento de entradas inválidas.

Planejadas para etapas futuras: HTTPS/Certbot, DNS e firewall (somente quando explicitamente projetados).

## Validação e teste manual

Os comandos abaixo não executam alterações remotas:

```bash
bash -n apache-manager.sh
.venv/bin/ansible-playbook --syntax-check -i inventory/hosts.example.yml playbooks/diagnose.yml
.venv/bin/ansible-playbook --syntax-check -i inventory/hosts.example.yml playbooks/install.yml
.venv/bin/ansible-playbook --syntax-check -i inventory/hosts.example.yml playbooks/deploy-site.yml
.venv/bin/ansible-playbook --syntax-check -i inventory/hosts.example.yml playbooks/teardown.yml
.venv/bin/ansible-inventory -i inventory/hosts.example.yml --list
```

Para testar com um Ubuntu, confirme `ssh <alias>`, execute a CLI, cadastre o host, abra **Gerenciar servidores > Testar conectividade** e depois **Instalar Apache**. A CLI pode solicitar a senha de `sudo` por meio do próprio Ansible; ela não é armazenada.

Depois da instalação, valide no servidor:

```bash
apache2ctl -v
sudo apache2ctl configtest
systemctl is-active apache2
systemctl is-enabled apache2
ss -ltnp 'sport = :80'
```

Para um teste real direto, fora do menu e somente após revisar os hosts selecionados:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/install.yml --limit dev-lab --ask-become-pass
```

## Suposições e limitações

- alvos desta etapa são Ubuntu/Debian com systemd, `dpkg-query` e `ss`;
- o inventário é mantido pela CLI; edições manuais devem preservar a estrutura do exemplo;
- indisponibilidade SSH aparece no resumo do Ansible, pois não é possível montar um relatório remoto sem conexão;
- a instalação usa a porta HTTP padrão 80 e bloqueia cenários ambíguos em vez de tentar reconfigurar serviços;
- a publicação usa HTTP em uma porta validada entre 1 e 65535 e não cria registros DNS;
- a validação utiliza um arquivo oculto gerenciado dentro do DocumentRoot; ele não contém credenciais;
- hosts completamente inacessíveis aparecem no resumo do Ansible, sem relatório remoto detalhado;
- nenhum dado real de servidor ou credencial é fornecido ou versionado.
