# Documentação do Banco de Dados - IBME

📚 Documentação completa do banco de dados do Instituto Brasileiro de Música e Educação (IBME).

## 📖 Navegação Rápida

### Documentos Principais

1. **[Estrutura do Banco de Dados](./documentacao-banco-dados.md)**
   - Visão geral das tabelas e relacionamentos
   - Entidades centrais (Alunos, Professores, Responsáveis)
   - Estrutura educacional (Programas, Turmas, Agendamentos)
   - Sistema de presença
   - Pesquisas e avaliações
   - Perfil sociocultural
   - Views e casos de uso

2. **[Funções e Triggers](./documentacao-funcoes-triggers.md)**
   - Funções de gerenciamento de presença
   - Funções de pesquisas e estatísticas
   - Funções de perfil sociocultural
   - Triggers automáticos
   - Fluxos de trabalho
   - Boas práticas e troubleshooting

3. **[Schema SQL](./schema.sql)**
   - Arquivo SQL completo com a estrutura do banco
   - DDL de todas as tabelas
   - Definições de funções e triggers
   - Índices e constraints

---

## 🎯 Sobre o Projeto

O banco de dados do IBME é projetado para gerenciar um programa educacional musical completo, incluindo:

- Gestão de alunos, professores e responsáveis
- Controle de programas e turmas
- Sistema de presença automatizado com particionamento
- Pesquisas de satisfação e impacto
- Indicadores socioeconômicos
- Relatórios e estatísticas

---

## 🏗️ Estrutura do Repositório

```
database_docs/
├── README.md                              # Este arquivo
├── documentacao-banco-dados.md            # Documentação das tabelas e relacionamentos
├── documentacao-funcoes-triggers.md       # Documentação das funções e triggers
├── schema.sql                             # Arquivo SQL completo
└── .gitignore                             # Arquivos ignorados pelo Git
```

---

## 🚀 Início Rápido

### Para Desenvolvedores

1. **Entender a estrutura básica**
   - Comece lendo [Documentação do Banco de Dados](./documentacao-banco-dados.md)
   - Foque nas [Entidades Centrais](./documentacao-banco-dados.md#-entidades-centrais)
   - Entenda os [Principais Relacionamentos](./documentacao-banco-dados.md#-principais-relacionamentos)

2. **Trabalhar com presença**
   - Veja as [Funções de Presença](./documentacao-funcoes-triggers.md#gerenciamento-de-presença-attendance)
   - Entenda o [Fluxo de Agendamento](./documentacao-funcoes-triggers.md#fluxo-1-criar-agendamento-e-registrar-presença)

3. **Gerar relatórios**
   - Use as [Funções de Estatísticas](./documentacao-funcoes-triggers.md#pesquisas-e-estatísticas)
   - Consulte [Funções Socioculturais](./documentacao-funcoes-triggers.md#perfil-sociocultural)

### Para Administradores

1. **Compreender o sistema**
   - Leia a [Visão Geral](./documentacao-banco-dados.md#visão-geral)
   - Revise os [Casos de Uso](./documentacao-banco-dados.md#-casos-de-uso-principais)

2. **Manutenção do banco**
   - Consulte [Manutenção Recomendada](./documentacao-funcoes-triggers.md#-manutenção-recomendada)
   - Veja [Troubleshooting](./documentacao-funcoes-triggers.md#-troubleshooting)

---

## 📊 Principais Funcionalidades

### 1. Sistema de Presença Automatizado
- ✅ Criação automática de registros ao agendar aulas
- ✅ Atualização em massa de presença
- ✅ Cálculo automático de taxa de frequência
- ✅ Particionamento por ano para performance

[Ver documentação completa →](./documentacao-funcoes-triggers.md#gerenciamento-de-presença-attendance)

### 2. Pesquisas e Avaliações
- ✅ Pesquisa de satisfação de alunos
- ✅ Pesquisa de satisfação de pais
- ✅ Pesquisa de impacto nos alunos
- ✅ Pesquisa de impacto nos professores
- ✅ Monitoramento do programa Sinta o Som

[Ver documentação completa →](./documentacao-funcoes-triggers.md#pesquisas-e-estatísticas)

### 3. Indicadores Socioeconômicos
- ✅ Perfil sociocultural dos alunos
- ✅ Renda familiar e per capita
- ✅ Escolaridade dos pais
- ✅ Acesso a serviços públicos
- ✅ Impacto econômico das bolsas

[Ver documentação completa →](./documentacao-banco-dados.md#-indicadores-e-perfil-sociocultural)

### 4. Relatórios e Dashboards
- ✅ Estatísticas agregadas por filtros diversos
- ✅ Dados prontos para visualização
- ✅ Export em formato JSON
- ✅ Performance otimizada

[Ver documentação completa →](./documentacao-funcoes-triggers.md#pesquisas-e-estatísticas)

---

## 🔗 Links Úteis

### Documentação Interna
- [Estrutura de Tabelas](./documentacao-banco-dados.md#estrutura-principal)
- [Relacionamentos](./documentacao-banco-dados.md#-principais-relacionamentos)
- [Funções SQL](./documentacao-funcoes-triggers.md#-funções-detalhadas)
- [Triggers](./documentacao-funcoes-triggers.md#triggers-auxiliares)
- [Views](./documentacao-banco-dados.md#-views-visões)

### Guias Práticos
- [Como criar um agendamento](./documentacao-funcoes-triggers.md#bulk_create_schedules)
- [Como registrar presença](./documentacao-funcoes-triggers.md#bulk_update_attendance_by_student)
- [Como gerar relatórios](./documentacao-funcoes-triggers.md#get_all_sociocultural_stats)
- [Como criar partições](./documentacao-funcoes-triggers.md#create_attendance_partition)

---

## 🛠️ Tecnologias

- **PostgreSQL** 14+
- **PL/pgSQL** (Linguagem procedural)
- **Particionamento de tabelas** (Range partitioning)
- **JSONB** (Dados estruturados)
- **Triggers** (Automação)
- **Views** (Consultas otimizadas)

---

## 📈 Estatísticas do Banco

- **Tabelas principais:** 40+
- **Views:** 3
- **Funções:** 30+
- **Triggers:** 6
- **Partições de presença:** 5 (2024-2027 + default)
- **Tabelas de relacionamento:** 4

---

## 🤝 Contribuindo

Para contribuir com melhorias na documentação:

1. Clone este repositório
2. Faça suas alterações
3. Envie um pull request

---

## 📞 Contato

Para dúvidas ou sugestões sobre a documentação do banco de dados, entre em contato com a equipe técnica do IBME.

---

## 📝 Licença

Documentação proprietária do Instituto Brasileiro de Música e Educação (IBME).

---

## 🔄 Última Atualização

**Data:** Janeiro 2026
**Versão do Schema:** Atual
**Status:** Documentação completa e atualizada

---

<div align="center">

**[⬆ Voltar ao topo](#documentação-do-banco-de-dados---ibme)**

</div>
