# Documentação do Banco de Dados - IBME

> 📖 **Navegação:** [← Início](./README.md) | [Funções e Triggers →](./documentacao-funcoes-triggers.md) | [Schema SQL](./schema.sql)

---

## Visão Geral

Este banco de dados foi projetado para gerenciar um programa educacional musical, controlando informações sobre alunos, professores, turmas, presença, programas educacionais e pesquisas de satisfação e impacto.

### 📑 Índice Rápido

- [Entidades Centrais](#-entidades-centrais) - Alunos, Professores, Responsáveis
- [Estrutura Educacional](#-estrutura-educacional) - Programas, Turmas, Agendamentos
- [Controle de Presença](#-controle-de-presença) - Sistema de attendance
- [Tabelas de Relacionamento](#-tabelas-de-relacionamento-many-to-many) - Conexões N:N
- [Pesquisas e Avaliações](#-pesquisas-e-avaliações) - Satisfação e impacto
- [Perfil Sociocultural](#-indicadores-e-perfil-sociocultural) - Dados socioeconômicos
- [Inventário e Patrimônio](#-inventário-e-patrimônio) - Instrumentos e bens físicos
- [Projetos Especiais](#-projetos-especiais) - Caravana, Funarte, Santander, Treinamentos
- [Views](#-views-visões) - Consultas otimizadas
- [Relacionamentos](#-principais-relacionamentos) - Mapa de conexões
- [Casos de Uso](#-casos-de-uso-principais) - Exemplos práticos

**💡 Veja também:** [Funções e Triggers](./documentacao-funcoes-triggers.md) para entender a automação do sistema.

## Estrutura Principal

### 🎓 Entidades Centrais

#### **Students (Alunos)**
A tabela `Students` é uma das entidades centrais do sistema. Ela armazena todas as informações dos alunos matriculados nos programas.

**Informações armazenadas:**
- Dados pessoais (nome completo, data de nascimento, CPF, RG, endereço)
- Dados de contato (email, telefone, responsáveis)
- Dados acadêmicos (nível de educação, turno, escola, programa matriculado)
- Dados bancários e documentos (para bolsas e auxílios)
- Informações médicas (alergias, necessidades especiais)
- Status do aluno (ativo, expulso, semestre de matrícula/desligamento)
- Instrumentos e inventário
- Foto e assinatura digital

**Chave primária:** `unique id`

#### **Teachers (Professores)**
Armazena informações completas sobre os professores que ministram as aulas.

**Informações armazenadas:**
- Dados pessoais (nome completo, data de nascimento, CPF, RG, endereço)
- Dados de contato (email, telefone)
- Formação acadêmica (grau mais alto, instituição de ensino, curso)
- Dados profissionais (instrumento que ensina, status, taxa horária)
- Dados bancários (para pagamentos)
- Currículo, biografia e foto
- Informações sobre turmas que leciona

**Chave primária:** `unique id`

#### **Parents (Responsáveis)**
Contém dados dos pais ou responsáveis legais pelos alunos.

**Informações armazenadas:**
- Dados pessoais (nome, CPF, RG, grau de parentesco)
- Dados de contato (email, telefone, melhor horário para contato)
- Endereço completo
- Documentos e assinaturas digitais
- Vínculo com o estudante (`id_student_ibme`)

**Chave primária:** `unique id`

---

### 📚 Estrutura Educacional

#### **programs (Programas)**
Representa os diferentes programas educacionais oferecidos pela instituição.

**Informações armazenadas:**
- Nome e descrição do programa
- Localização (endereço completo)
- Administrador e assistente responsável
- Taxa de retenção do programa
- Datas de criação e modificação

**Chave primária:** `unique_id`

**Relacionamentos:**
- Possui muitas turmas através de `program_classes`
- Possui muitos instrumentos através de `program_instruments`
- Possui muitos patrocinadores através de `program_patrocinadores`
- Possui muitos professores através de `program_teachers`

#### **class (Turmas)**
Representa as turmas/aulas específicas dentro dos programas.

**Informações armazenadas:**
- Código da turma e localização
- Programa ao qual pertence
- Dia da semana e horário de início
- Data de início e término
- Duração da aula
- Número máximo de alunos
- Professores que lecionam
- Instrumento(s) ensinado(s)
- Ensemble (grupo musical)

**Chave primária:** `unique_id`

**Relacionamentos:**
- Pertence a um ou mais programas através de `program_classes`
- Possui muitos agendamentos através de `schedule`

#### **schedule (Agendamento)**
Gerencia o cronograma específico de cada aula, permitindo o controle dia a dia.

**Informações armazenadas:**
- Data da aula
- Duração
- Taxa de presença
- ID da turma e do professor
- Se a presença já foi registrada

**Chave primária:** `unique_id`

**Relacionamentos:**
- Pertence a uma turma (`class_id` → `class.unique_id`)
- Pertence a um professor (`teacher_id` → `Teachers.unique id`)
- Possui registros de presença através de `attendance`

---

### 📊 Controle de Presença

#### **attendance (Presença)**
Esta é uma tabela particionada por data que registra a presença dos alunos em cada aula.

**Informações armazenadas:**
- Data da presença (`attendance_date`)
- ID do agendamento (`schedule_id`)
- ID do aluno (`student_id`)
- Status (presente, ausente, falta justificada)
- Observações

**Particionamento:** A tabela é dividida em partições anuais:
- `attendance_2024`
- `attendance_2025`
- `attendance_2026`
- `attendance_2027`
- `attendance_default` (para datas fora dos intervalos específicos)

**Relacionamentos:**
- Pertence a um agendamento (`schedule_id` → `schedule.unique_id`)
- Pertence a um aluno (`student_id` → `Students.unique id`)

#### **Rate students (Taxa de Alunos)**
Calcula e armazena métricas de frequência dos alunos.

**Informações armazenadas:**
- Taxa de presença calculada
- Número de faltas, faltas justificadas e presenças
- Total de aulas no período
- Programa e ano

---

### 🔗 Tabelas de Relacionamento (Many-to-Many)

#### **program_classes**
Conecta programas às suas turmas.
- `program_id` → `programs.unique_id`
- `class_unique_id` → `class.unique_id`

#### **program_teachers**
Conecta programas aos seus professores.
- `program_id` → `programs.unique_id`
- `teacher_unique_id` → `Teachers.unique id`

#### **program_instruments**
Conecta programas aos instrumentos disponíveis.
- `program_id` → `programs.unique_id`
- `instrument_os_id` → `instrument_os.id`

#### **program_patrocinadores**
Conecta programas aos seus patrocinadores.
- `program_id` → `programs.unique_id`
- `sponsor_id` → `sponsors.unique_id`

---

### 🎵 Recursos e Apoio

#### **instrument_os (Instrumentos)**
Lista de instrumentos musicais disponíveis.

**Informações armazenadas:**
- Nome em inglês e português

#### **sponsors (Patrocinadores)**
Empresas e organizações que patrocinam os programas.

**Informações armazenadas:**
- Nome e descrição
- Logo (URL da imagem)

---

### 📋 Pesquisas e Avaliações

#### **student_satisfaction_survey (Pesquisa de Satisfação do Aluno)**
Avalia a satisfação dos alunos em relação aos professores e ao programa.

**Campos avaliados:**
- Se o professor é pontual, organizado e paciente
- Se o aluno se sente confortável fazendo perguntas
- Se respeita o professor
- Se o professor trata todos com justiça
- Se o professor é um bom modelo
- Se gostaria de ter o mesmo professor no próximo ano
- Comentários abertos sobre o professor

**Relacionamento:**
- Vinculado ao aluno (`student` → `Students.unique id`)
- Vinculado ao professor avaliado (`teacher`)

#### **parent_satisfaction_survey (Pesquisa de Satisfação dos Pais)**
Coleta feedback dos responsáveis sobre o programa.

**Informações coletadas:**
- 23 perguntas (q1 até q23)
- Score calculado
- Data de criação

**Relacionamento:**
- Vinculado ao aluno (`student` → `Students.unique id`)

#### **student_impact_survey (Pesquisa de Impacto no Aluno)**
Avalia o impacto do programa no desenvolvimento do aluno.

**Informações coletadas:**
- 9 perguntas sobre diferentes aspectos do impacto
- Score calculado

**Relacionamento:**
- Vinculado ao aluno (`student` → `Students.unique id`)

#### **teacher_impact_survey (Pesquisa de Impacto no Professor)**
Avalia como o programa impacta os professores.

---

### 📈 Indicadores e Perfil Sociocultural

#### **Sociocultural Profile (Perfil Sociocultural)**
Coleta informações socioeconômicas e culturais dos alunos para avaliar o impacto social do programa.

**Informações armazenadas:**
- Se mora em comunidade e qual
- Escolaridade dos pais
- Renda familiar mensal
- Quantidade de moradores
- Se recebe benefícios sociais
- Se mora em área de risco
- Região e pavimentação
- Serviços e políticas públicas acessados

**Relacionamento:**
- Vinculado ao aluno através do campo `student`
- Estudantes podem referenciar o perfil através de `Students.perfil_sociocultural`

#### **indicadores_ibme (Indicadores IBME)**
Armazena indicadores específicos de impacto socioeconômico dos alunos.

**Informações coletadas:**
- Situação de trabalho atual
- Oportunidades internacionais
- Renda familiar e per capita
- Bolsas recebidas e seu impacto
- Remuneração extra
- Cursos de música
- Ensino médio e superior

---

### 🎼 Programa "Sinta o Som"

Há um conjunto específico de tabelas dedicadas ao programa "Sinta o Som":

#### **survey_sinta_o_som_aluno**
Pesquisa aplicada aos alunos do programa Sinta o Som.

#### **sinta_o_som_survey_teacher**
Pesquisa aplicada aos professores do programa Sinta o Som.

#### **survey_monitoramento_sinta_som**
Monitora a aplicação da metodologia nas turmas do programa.

**Campos avaliados:**
- Aplicação da metodologia
- Conteúdo de sustentabilidade
- Conteúdo musical
- Nível de entusiasmo dos alunos
- Necessidades e desafios
- Observações gerais

**Relacionamento:**
- Vinculado a turma, professor e programa

#### **rel_media_survey_monitoramento_sinta_som**
Armazena URLs de mídias (fotos, vídeos) relacionadas às pesquisas de monitoramento.

#### **Survey_Masterclass_Sinta_Som**
Pesquisa aplicada em eventos de masterclass do programa Sinta o Som.

**Informações coletadas:**
- Avaliações dos participantes sobre a masterclass
- Feedback sobre conteúdo e qualidade
- Impacto do evento

#### **relatorios_sinta_som**
Armazena relatórios consolidados do programa Sinta o Som para análise e acompanhamento.

---

### 📦 Inventário e Patrimônio

#### **inventory (Inventário de Instrumentos)**
Gerencia o inventário de instrumentos musicais emprestados ou sob responsabilidade do programa.

**Informações armazenadas:**
- Identificação do item (marca, modelo, número de série, código)
- Instrumento e tamanho
- Condição atual (enum `condition_status`: `new`, `good`, `fair`, `poor`, `under_maintenance`, `retired`)
- Data de recebimento
- Proprietário (`owner`) e responsável atual (`issued_to` → aluno ou professor)
- Termo assinado e URL da assinatura do responsável
- Fotos e QR code (URL)
- Programa e campus ao qual pertence
- Campos de auditoria (admin, creator, created_date, modified_date)

**Chave primária:** `id` (UUID)

**Índices:** bubble_id, condition, instrument, issued_to, programa

**Tipo ENUM usado:** `condition_status` — valores: `new`, `good`, `fair`, `poor`, `under_maintenance`, `retired`

#### **patrimonio (Patrimônio Físico)**
Registra bens físicos (equipamentos, móveis, etc.) pertencentes à instituição, separados dos instrumentos do inventário.

**Informações armazenadas:**
- Código e descrição do bem
- Condição atual (enum `condition_status`)
- Data de recebimento e proprietário
- Programa e campus ao qual pertence
- Campos de auditoria (admin, creator, created_date, modified_date)

**Chave primária:** `id` (UUID)

**Índices:** bubble_id, condition, programa

**Diferença do `inventory`:** O patrimônio registra bens gerais da instituição (sem vínculo de empréstimo a alunos), enquanto `inventory` rastreia instrumentos com controle de quem está com o item.

---

### 🚀 Projetos Especiais

#### **caravana_sinta_o_som**
Registra as caravanas realizadas no programa Sinta o Som, com informações geográficas e de patrocínio.

**Informações armazenadas:**
- Cidade e estado onde ocorreu a caravana
- Patrocinador responsável
- ID único da caravana

**Relacionamento:**
- Vinculada à `Customer Satisfaction Survey` através do campo `caravana` (preenchido automaticamente pela função `assign_caravana_to_customer_survey`)

#### **Santander_Formularios**
Armazena respostas de formulários do projeto Santander.

**Informações armazenadas:**
- ID do formulário (`form_id`) e ID da resposta (`response_id`)
- Campos de resposta: q1, q2_a, q2_b, q2_c, q2_d
- Referência ao registro no Bubble (`bubble_id`)
- Data de criação

**Políticas de acesso:** Permissiva para autenticados e anônimos.

#### **Inscriçãoes Treinamento**
Gerencia inscrições em eventos e treinamentos promovidos pelo IBME.

**Informações armazenadas:**
- Nome completo, email e cargo do participante
- Tamanho da camisa e segmento
- Autorização de uso de imagem
- Cidade, estado e patrocinador vinculado
- Nome do treinamento
- Referência ao registro no Bubble (`bubble_unique_id`)

#### **funarate_avaliacao_responsaveis**
Coleta avaliações dos responsáveis em eventos da Funarte.

**Informações armazenadas:**
- Avaliações por categoria: acesso à cultura (q1, q2), desenvolvimento pessoal (q1-q5, escala numérica), impacto educacional (q1, q2), avaliação das atividades (q1, q2)
- Campo de sugestões abertas
- ID e timestamps

**Políticas de acesso:** Acesso total para anônimos.

#### **funarte_avaliacao_aluno**
Coleta avaliações dos alunos em eventos da Funarte.

**Políticas de acesso:** Leitura e inserção permitidas para anônimos.

---

### 🛠️ Tabelas Auxiliares

#### **app_logs**
Registra logs da aplicação para monitoramento e debugging.

**Informações armazenadas:**
- Timestamp
- Nível do log (debug, info, warn, error, fatal)
- Tipo e nome do evento
- ID do usuário e sessão
- URL da página
- Mensagem de erro e stack trace
- Contexto (JSON)
- User agent e IP
- Versão da aplicação

#### **students_invite_code**
Gerencia códigos de convite para alunos (provavelmente para acesso ao sistema).

**Informações armazenadas:**
- Código de convite (gerado aleatoriamente)
- ID do estudante
- Passo/etapa do processo

#### **Customer Satisfaction Survey**
Pesquisa genérica de satisfação do cliente/comunidade.

#### **Customer Satisfaction Survey options**
Armazena as opções de resposta disponíveis para a pesquisa de satisfação do cliente.

**Informações armazenadas:**
- Opções de resposta padronizadas
- Escalas de avaliação
- Categorias de feedback

#### **survey_statements (Declarações de Pesquisa)**
Armazena as declarações/perguntas usadas nas pesquisas.

#### **wake_up_supabase**
Tabela técnica utilizada para manter o banco de dados ativo em ambientes serverless.

**Propósito:**
- Prevenir hibernação do banco em ambientes como Supabase free tier
- Mantém atividade mínima através da função `rotate_wake_up()`
- Evita cold starts em aplicações críticas

---

## 📊 Views (Visões)

#### **student_full_profile**
Combina dados de `Students` com `Sociocultural Profile` para fornecer uma visão completa do perfil do aluno.

#### **student_teachers_connection**
Mostra a conexão entre alunos ativos e seus professores através das turmas.

**Campos retornados:**
- Nome completo e DOB do aluno
- IDs das turmas
- IDs dos professores

#### **students_dob**
Lista simples de alunos com data de nascimento, ordenada por nome.

---

## 🔑 Principais Relacionamentos

### Aluno é o centro do sistema:
1. **Aluno → Responsáveis**: Um aluno pode ter múltiplos responsáveis (Pai 1, Pai 2) através de `Parents.id_student_ibme`
2. **Aluno → Perfil Sociocultural**: Relacionamento 1:1 através de `Students.perfil_sociocultural`
3. **Aluno → Turmas**: Relacionamento implícito através do campo texto `Students.Classes`
4. **Aluno → Presença**: Um aluno tem muitos registros de presença através de `attendance.student_id`
5. **Aluno → Pesquisas**: Um aluno pode responder múltiplas pesquisas (satisfação, impacto, indicadores)

### Programa conecta todos os recursos:
1. **Programa → Turmas**: Many-to-many através de `program_classes`
2. **Programa → Professores**: Many-to-many através de `program_teachers`
3. **Programa → Instrumentos**: Many-to-many através de `program_instruments`
4. **Programa → Patrocinadores**: Many-to-many através de `program_patrocinadores`

### Fluxo de Aulas:
1. **Turma** → definida com informações gerais
2. **Schedule** → agenda específica de quando a aula ocorre
3. **Attendance** → registra a presença de cada aluno em cada agendamento

---

## 💡 Observações Importantes

### Particionamento
A tabela `attendance` usa particionamento por ano para melhorar a performance em consultas históricas. Isso é essencial dado o alto volume de registros de presença ao longo do tempo.

### Soft Deletes e Cascatas
- Algumas relações usam `ON DELETE CASCADE` (quando o pai é deletado, os filhos também são)
- Outras usam `ON DELETE RESTRICT` (impede a exclusão se houver registros relacionados)
- A maioria das tabelas principais mantém histórico através de campos de data e status

### Campos de Auditoria
A maioria das tabelas possui:
- `created_date` / `Creation Date`: data de criação
- `modified_date` / `Modified Date`: data da última modificação
- `creator` / `Creator`: usuário que criou
- `admin` / `Admin`: administrador responsável

### IDs e Slugs
- As tabelas usam `unique id` (texto) como chave primária
- Muitas tabelas possuem `slug` para URLs amigáveis
- Algumas tabelas auto-incrementam IDs numéricos adicionalmente

---

## 🎯 Casos de Uso Principais

### 1. Matrícula de Novo Aluno
1. Criar registro em `Students`
2. Criar registro(s) em `Parents`
3. Criar registro em `Sociocultural Profile`
4. Associar a um programa através de `Students.Programa`
5. Associar a turma(s) através de `Students.Classes`

### 2. Registro de Presença
1. Buscar agendamento em `schedule` pela data e turma
2. Para cada aluno da turma, criar registro em `attendance`
3. Atualizar `schedule.presenca_anotada = true`
4. Sistema calcula automaticamente a taxa de presença

### 3. Pesquisa de Satisfação
1. Aluno recebe código de convite em `students_invite_code`
2. Aluno responde pesquisa
3. Dados salvos em `student_satisfaction_survey`
4. Score calculado automaticamente

### 4. Relatórios de Impacto
1. Combinar dados de `student_full_profile` (view)
2. Incluir dados de `indicadores_ibme`
3. Incluir dados de `student_impact_survey`
4. Calcular métricas de retenção, frequência e progressão
5. Analisar impacto socioeconômico

---

## 📝 Conclusão

Este banco de dados é robusto e bem estruturado para gerenciar um programa educacional musical completo. Ele não apenas controla operações diárias (turmas, presença, professores), mas também coleta dados valiosos para avaliar o impacto social e educacional do programa através de pesquisas e indicadores socioeconômicos.

A estrutura permite rastreabilidade completa, desde a matrícula do aluno até seu desenvolvimento ao longo do tempo, passando por todas as interações com professores, turmas e programas.

---

## 🔗 Próximos Passos

- **[Ver Funções e Triggers →](./documentacao-funcoes-triggers.md)** - Entenda como o sistema automatiza processos
- **[Voltar ao Início ←](./README.md)** - Página principal da documentação
- **[Ver Schema SQL](./schema.sql)** - Código SQL completo

---

<div align="center">

**[⬆ Voltar ao topo](#documentação-do-banco-de-dados---ibme)**

</div>
