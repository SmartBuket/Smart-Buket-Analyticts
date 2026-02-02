# PETS v1.1 – Paquete Estándar de Tecnologías SmartBuket

## 1. Propósito del documento

El presente documento define el Paquete Estándar de Tecnologías SmartBuket (PETS v1.1). Su función es servir como constitución técnica del ecosistema SmartBuket, estableciendo un marco obligatorio de tecnologías, patrones, contratos y reglas operativas que garantizan seguridad, trazabilidad, escalabilidad y coherencia entre todas las aplicaciones.

El PETS:

- No obliga a usar todo el stack en todos los proyectos.
- Define un conjunto cerrado de tecnologías aprobadas.
- Establece reglas claras para seleccionar subconjuntos según el tipo de aplicación.
- Garantiza compatibilidad obligatoria con el Generador de Licencias, Exactus, SmartComm y SmartBuket Analytics.

**Principio rector:** entre lo más rápido y lo más seguro, prima siempre lo más seguro.

---

## 2. Alcance

El PETS aplica a:

- Nuevos proyectos SmartBuket.
- Refactorización o migración de proyectos existentes.
- Integraciones entre aplicaciones del ecosistema.

No aplica a:

- Pruebas experimentales sin impacto productivo.

Toda excepción debe documentarse y aprobarse explícitamente.

---

## 3. Gobernanza tecnológica

- El stack aprobado es cerrado.
- No se introduce un nuevo lenguaje, framework o middleware sin justificación técnica y de negocio.
- Las decisiones de seguridad, contratos y autenticación definidas en este documento son no negociables.

---

## 4. Lenguajes y runtimes aprobados

### Backend

- Python 3.11+ (estándar principal)
- .NET 8.0 + C# 12 (estándar enterprise)

### Frontend

- HTML5 / CSS3 / JavaScript ES6+
- Blazor WebAssembly (cuando el backend es .NET)

**Regla:** no se introduce un tercer stack backend sin aprobación formal.

---

## 5. Backend estándar – Python

### Framework y librerías base

- Flask 2.x
- SQLAlchemy 2.x
- Alembic / Flask-Migrate
- PostgreSQL (psycopg2 o psycopg v3)
- Pydantic (validación estricta)

### Seguridad obligatoria

- CSRF: Flask-WTF (cuando haya formularios)
- Hashing de contraseñas: Werkzeug (scrypt)
- JWT: RS256 con PyJWT
- Rate limiting: Flask-Limiter
- CORS: Flask-CORS

### Procesos asíncronos

- Redis (cache y colas)
- Celery + Redis o RQ + Redis

---

## 6. Backend estándar – .NET

- .NET 8
- ASP.NET Core (APIs)
- Blazor WebAssembly (UI)
- Entity Framework Core + Migrations
- Microsoft.Extensions.Logging

### Seguridad

- JWT RS256 con Microsoft.IdentityModel.Tokens

**Regla:** aplicaciones productivas no pueden usar persistencia in-memory.

---

## 7. Bases de datos

### Primaria

- PostgreSQL (estándar del ecosistema)

### Complementarias

- Redis (cache, sesiones, rate limiting, colas)
- SQLite (solo apps locales/desktop)

---

## 8. Política de seguridad mínima (obligatoria)

### Activos críticos

- Credenciales y tokens
- Licencias y pagos
- Datos personales (PII)
- Eventos de negocio

### Controles mínimos

- TLS obligatorio
- Headers de seguridad (HSTS, X-Frame-Options, etc.)
- Rate limit en endpoints críticos
- Cifrado en reposo para credenciales, tokens y PII
- Prohibido registrar PII en logs
- Principio de menor privilegio

---

## 9. Autenticación y autorización (decisión cerrada)

### JWT estándar del ecosistema

Claims obligatorios:

- iss
- aud (por aplicación)
- sub
- exp
- iat
- nbf
- jti
- kid
- roles / scopes

### Ciclo de vida

- Access token: corto (10–20 minutos)
- Refresh token: rotación obligatoria
- Revocación por jti o token_version

### Roles y permisos

- RBAC mínimo obligatorio
- Auditoría: actor, acción, fecha, origen

---

## 10. Integración entre aplicaciones

### Principio fundamental

Ninguna aplicación se integra directamente sin contrato.

### Mecanismos permitidos

- APIs versionadas (OpenAPI 3.0)
- Eventos (RabbitMQ)

---

## 11. Contratos SmartBuket (obligatorios)

- OpenAPI 3.0 para APIs
- JSON Schema para eventos

### Gobernanza

- Repositorio único de contratos
- Versionado SemVer
- Compatibilidad hacia atrás obligatoria
- Política de deprecación N-1
- Validación automática por CI

---

## 12. Mensajería y eventos

### Broker

- RabbitMQ (exchange tipo topic, durable)

### Garantías

- At-least-once delivery
- Idempotencia obligatoria
- DLQ obligatoria por consumidor
- Retry con backoff exponencial

### Envelope estándar de evento

Campos mínimos:

- event_id (UUID)
- event_name
- event_version
- occurred_at
- trace_id
- app_uuid
- producer
- actor
- payload

---

## 13. Outbox Pattern (obligatorio)

### Esquema mínimo

- id
- event_name
- event_version
- payload
- trace_id
- occurred_at
- status
- retries
- last_error

### Operación

- Poller con locking
- Métricas de backlog y errores

---

## 14. SmartBuket SDKs (obligatorios)

SDKs oficiales:

- smartbuket-sdk-python
- smartbuket-sdk-dotnet
- smartbuket-sdk-js

Funciones mínimas:

- identify()
- track()
- emit_business_event()

Gestión automática de:

- session_id
- trace_id
- retries
- buffering

---

## 15. SmartBuket Analytics

### Eventos mínimos

- session.started
- session.ended
- screen.viewed
- action.performed
- error.occurred

### Campos obligatorios

- app_uuid
- user_uuid / anonymous_id
- session_id
- occurred_at
- device
- geo
- screen
- metadata

**Regla:** ningún evento se envía sin SDK.

---

## 16. Observabilidad

- Logs estructurados en JSON
- trace_id obligatorio
- Métricas mínimas: latencia, errores, backlog, DLQ
- Alertas operativas básicas

---

## 17. Deployment y operación

- Docker obligatorio
- docker-compose en desarrollo
- Entornos: dev / stage / prod
- Migraciones controladas
- Health checks
- Rollback definido

---

## 18. Tipos de aplicación

- **Tipo A – Panel administrativo:** Flask + Jinja2 + PostgreSQL
- **Tipo B – Enterprise:** .NET 8 + Blazor + PostgreSQL
- **Tipo C – E-commerce:** Flask + PostgreSQL + RabbitMQ
- **Tipo D – Desktop:** Python + PyQt + SQLite (cifrada)

---

## 19. Plantilla obligatoria de inicio de proyecto

- Tipo de aplicación
- Subconjunto PETS
- Tecnologías excluidas y justificación
- Integración con GL
- Eventos enviados

---

## 20. Cierre

El PETS v1.1 establece un estándar suficiente, eficiente y seguro para todos los desarrollos SmartBuket. Su objetivo no es limitar la innovación, sino garantizar que cada avance sea sostenible, auditable y escalable dentro del ecosistema.
