#include <erl_nif.h>
#include <git2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PATH_BUFSZ 4096
#define HEX_BUFSZ (GIT_OID_MAX_HEXSIZE + 1)

typedef struct repo_lock {
    char *key;
    ErlNifMutex *mutex;
    unsigned refs;
    struct repo_lock *next;
} repo_lock;

typedef struct {
    git_repository *repo;
    repo_lock *shared;
    ErlNifMonitor monitor;
    int monitored;
} ex_git_repo;

static ErlNifResourceType *REPO_RESOURCE = NULL;
static ErlNifMutex *LOCK_TABLE_MUTEX = NULL;
static repo_lock *LOCK_TABLE = NULL;

static ERL_NIF_TERM ATOM_OK;
static ERL_NIF_TERM ATOM_ERROR;
static ERL_NIF_TERM ATOM_NIL;
static ERL_NIF_TERM ATOM_TRUE;
static ERL_NIF_TERM ATOM_FALSE;
static ERL_NIF_TERM ATOM_NEW;
static ERL_NIF_TERM ATOM_MODIFIED;
static ERL_NIF_TERM ATOM_DELETED;
static ERL_NIF_TERM ATOM_RENAMED;
static ERL_NIF_TERM ATOM_TYPECHANGE;
static ERL_NIF_TERM ATOM_CONFLICTED;
static ERL_NIF_TERM ATOM_IGNORED;
static ERL_NIF_TERM ATOM_UNREADABLE;
static ERL_NIF_TERM ATOM_PATH;
static ERL_NIF_TERM ATOM_STAGED;
static ERL_NIF_TERM ATOM_UNSTAGED;
static ERL_NIF_TERM ATOM_OLD_PATH;
static ERL_NIF_TERM ATOM_BRANCH;
static ERL_NIF_TERM ATOM_ENTRIES;
static ERL_NIF_TERM ATOM_NAME;
static ERL_NIF_TERM ATOM_CURRENT;
static ERL_NIF_TERM ATOM_OID;
static ERL_NIF_TERM ATOM_MESSAGE;
static ERL_NIF_TERM ATOM_SUMMARY;
static ERL_NIF_TERM ATOM_AUTHOR;
static ERL_NIF_TERM ATOM_EMAIL;
static ERL_NIF_TERM ATOM_TIME;
static ERL_NIF_TERM ATOM_UNBORN;
static ERL_NIF_TERM ATOM_DETACHED;
static ERL_NIF_TERM ATOM_NOT_FOUND;
static ERL_NIF_TERM ATOM_INVALID;
static ERL_NIF_TERM ATOM_CONFLICT;
static ERL_NIF_TERM ATOM_LOCKED;
static ERL_NIF_TERM ATOM_NOTHING_TO_COMMIT;
static ERL_NIF_TERM ATOM_CLOSED;
static ERL_NIF_TERM ATOM_NOMEM;

static ERL_NIF_TERM make_binary(ErlNifEnv *env, const char *str)
{
    if (!str) {
        str = "";
    }
    size_t len = strlen(str);
    ERL_NIF_TERM term;
    unsigned char *buf = enif_make_new_binary(env, len, &term);
    memcpy(buf, str, len);
    return term;
}

static ERL_NIF_TERM make_binary_n(ErlNifEnv *env, const char *str, size_t len)
{
    ERL_NIF_TERM term;
    unsigned char *buf = enif_make_new_binary(env, len, &term);
    if (len) {
        memcpy(buf, str, len);
    }
    return term;
}

static ERL_NIF_TERM git_code_atom(int error)
{
    switch (error) {
    case GIT_ENOTFOUND:
        return ATOM_NOT_FOUND;
    case GIT_EINVALIDSPEC:
    case GIT_EINVALID:
        return ATOM_INVALID;
    case GIT_ECONFLICT:
        return ATOM_CONFLICT;
    case GIT_ELOCKED:
        return ATOM_LOCKED;
    case GIT_EUNBORNBRANCH:
        return ATOM_UNBORN;
    default:
        return ATOM_ERROR;
    }
}

static ERL_NIF_TERM make_error_term(ErlNifEnv *env, ERL_NIF_TERM code, const char *fallback)
{
    const git_error *err = git_error_last();
    const char *msg = (err && err->message) ? err->message : fallback;
    return enif_make_tuple2(env, ATOM_ERROR, enif_make_tuple2(env, code, make_binary(env, msg)));
}

static ERL_NIF_TERM make_git_error(ErlNifEnv *env, int error, const char *fallback)
{
    return make_error_term(env, git_code_atom(error), fallback);
}

static ERL_NIF_TERM make_ok(ErlNifEnv *env, ERL_NIF_TERM value)
{
    return enif_make_tuple2(env, ATOM_OK, value);
}

static int inspect_cstr(ErlNifEnv *env, ERL_NIF_TERM term, char *buf, size_t buflen)
{
    ErlNifBinary bin;
    if (!enif_inspect_iolist_as_binary(env, term, &bin)) {
        return 0;
    }
    if (bin.size >= buflen) {
        return 0;
    }
    memcpy(buf, bin.data, bin.size);
    buf[bin.size] = 0;
    return 1;
}

static char *dup_cstr(ErlNifEnv *env, ERL_NIF_TERM term)
{
    ErlNifBinary bin;
    (void)env;
    if (!enif_inspect_iolist_as_binary(env, term, &bin)) {
        return NULL;
    }
    char *s = enif_alloc(bin.size + 1);
    if (!s) {
        return NULL;
    }
    memcpy(s, bin.data, bin.size);
    s[bin.size] = 0;
    return s;
}

static void free_strarray(git_strarray *arr)
{
    if (!arr || !arr->strings) {
        return;
    }
    for (size_t i = 0; i < arr->count; i++) {
        enif_free(arr->strings[i]);
    }
    enif_free(arr->strings);
    arr->strings = NULL;
    arr->count = 0;
}

static int list_to_strarray(ErlNifEnv *env, ERL_NIF_TERM list, git_strarray *arr)
{
    unsigned len = 0;
    if (!enif_get_list_length(env, list, &len)) {
        return 0;
    }

    arr->count = 0;
    arr->strings = NULL;
    if (len == 0) {
        return 1;
    }

    arr->strings = enif_alloc(sizeof(char *) * len);
    if (!arr->strings) {
        return 0;
    }
    memset(arr->strings, 0, sizeof(char *) * len);
    arr->count = len;

    ERL_NIF_TERM head, tail = list;
    for (unsigned i = 0; i < len; i++) {
        if (!enif_get_list_cell(env, tail, &head, &tail)) {
            free_strarray(arr);
            return 0;
        }
        arr->strings[i] = dup_cstr(env, head);
        if (!arr->strings[i]) {
            free_strarray(arr);
            return 0;
        }
    }
    return 1;
}

static char *dup_c_string(const char *src)
{
    size_t len = strlen(src);
    char *out = enif_alloc(len + 1);
    if (!out) {
        return NULL;
    }
    memcpy(out, src, len + 1);
    return out;
}

static char *repo_lock_key(git_repository *repo)
{
    const char *path = git_repository_path(repo);
    if (!path || !path[0]) {
        path = git_repository_workdir(repo);
    }
    if (!path || !path[0]) {
        return NULL;
    }
    return dup_c_string(path);
}

static repo_lock *acquire_repo_lock(const char *key)
{
    if (!LOCK_TABLE_MUTEX || !key) {
        return NULL;
    }

    enif_mutex_lock(LOCK_TABLE_MUTEX);
    for (repo_lock *cur = LOCK_TABLE; cur; cur = cur->next) {
        if (strcmp(cur->key, key) == 0) {
            cur->refs++;
            enif_mutex_unlock(LOCK_TABLE_MUTEX);
            return cur;
        }
    }

    repo_lock *created = enif_alloc(sizeof(repo_lock));
    if (!created) {
        enif_mutex_unlock(LOCK_TABLE_MUTEX);
        return NULL;
    }
    memset(created, 0, sizeof(*created));
    created->key = dup_c_string(key);
    created->mutex = enif_mutex_create("ex_git_repo_shared");
    if (!created->key || !created->mutex) {
        if (created->key) {
            enif_free(created->key);
        }
        if (created->mutex) {
            enif_mutex_destroy(created->mutex);
        }
        enif_free(created);
        enif_mutex_unlock(LOCK_TABLE_MUTEX);
        return NULL;
    }
    created->refs = 1;
    created->next = LOCK_TABLE;
    LOCK_TABLE = created;
    enif_mutex_unlock(LOCK_TABLE_MUTEX);
    return created;
}

static void release_repo_lock(repo_lock *lock)
{
    if (!lock || !LOCK_TABLE_MUTEX) {
        return;
    }

    enif_mutex_lock(LOCK_TABLE_MUTEX);
    repo_lock **slot = &LOCK_TABLE;
    while (*slot) {
        if (*slot == lock) {
            if (--lock->refs == 0) {
                *slot = lock->next;
                enif_mutex_unlock(LOCK_TABLE_MUTEX);
                enif_mutex_destroy(lock->mutex);
                enif_free(lock->key);
                enif_free(lock);
                return;
            }
            enif_mutex_unlock(LOCK_TABLE_MUTEX);
            return;
        }
        slot = &(*slot)->next;
    }
    enif_mutex_unlock(LOCK_TABLE_MUTEX);
}

static void close_repo_unlocked(ex_git_repo *r)
{
    if (r->repo) {
        git_repository_free(r->repo);
        r->repo = NULL;
    }
}

static void repo_dtor(ErlNifEnv *env, void *obj)
{
    (void)env;
    ex_git_repo *r = obj;
    repo_lock *shared = r->shared;
    if (shared) {
        enif_mutex_lock(shared->mutex);
        close_repo_unlocked(r);
        enif_mutex_unlock(shared->mutex);
        r->shared = NULL;
        release_repo_lock(shared);
    } else {
        close_repo_unlocked(r);
    }
}

static void repo_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *mon)
{
    (void)env;
    (void)pid;
    (void)mon;
    ex_git_repo *r = obj;
    repo_lock *shared = r->shared;
    if (shared) {
        enif_mutex_lock(shared->mutex);
        close_repo_unlocked(r);
        r->monitored = 0;
        enif_mutex_unlock(shared->mutex);
    }
    enif_release_resource(r);
}

static ERL_NIF_TERM wrap_repo(ErlNifEnv *env, git_repository *repo)
{
    char *key = repo_lock_key(repo);
    repo_lock *shared = key ? acquire_repo_lock(key) : NULL;
    if (key) {
        enif_free(key);
    }
    if (!shared) {
        git_repository_free(repo);
        return make_error_term(env, ATOM_NOMEM, "cannot create repository lock");
    }

    ex_git_repo *r = enif_alloc_resource(REPO_RESOURCE, sizeof(ex_git_repo));
    if (!r) {
        git_repository_free(repo);
        release_repo_lock(shared);
        return make_error_term(env, ATOM_NOMEM, "out of memory");
    }
    memset(r, 0, sizeof(*r));
    r->repo = repo;
    r->shared = shared;

    ErlNifPid self;
    enif_self(env, &self);
    if (enif_monitor_process(env, r, &self, &r->monitor) != 0) {
        r->shared = NULL;
        git_repository_free(repo);
        r->repo = NULL;
        enif_release_resource(r);
        release_repo_lock(shared);
        return make_error_term(env, ATOM_ERROR, "cannot monitor owner process");
    }
    r->monitored = 1;

    ERL_NIF_TERM term = enif_make_resource(env, r);
    /* Keep the allocation ref so owner-down can close immediately. */
    return make_ok(env, term);
}

static int get_repo(ErlNifEnv *env, ERL_NIF_TERM term, ex_git_repo **out)
{
    return enif_get_resource(env, term, REPO_RESOURCE, (void **)out);
}

static git_repository *lock_repo(ex_git_repo *r)
{
    if (!r->shared) {
        return NULL;
    }
    enif_mutex_lock(r->shared->mutex);
    if (!r->repo) {
        enif_mutex_unlock(r->shared->mutex);
        return NULL;
    }
    return r->repo;
}

static void unlock_repo(ex_git_repo *r)
{
    if (r->shared) {
        enif_mutex_unlock(r->shared->mutex);
    }
}

static ERL_NIF_TERM nif_loaded(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)env;
    (void)argc;
    (void)argv;
    return ATOM_TRUE;
}

static ERL_NIF_TERM nif_repo_init(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    char path[PATH_BUFSZ];
    if (!inspect_cstr(env, argv[0], path, sizeof(path))) {
        return enif_make_badarg(env);
    }

    git_repository_init_options opts = GIT_REPOSITORY_INIT_OPTIONS_INIT;
    opts.flags = GIT_REPOSITORY_INIT_MKPATH | GIT_REPOSITORY_INIT_NO_REINIT;
    opts.initial_head = "main";

    git_repository *repo = NULL;
    int error = git_repository_init_ext(&repo, path, &opts);
    if (error < 0) {
        return make_git_error(env, error, "init failed");
    }
    return wrap_repo(env, repo);
}

static ERL_NIF_TERM nif_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    char path[PATH_BUFSZ];
    char ceiling[PATH_BUFSZ];
    if (!inspect_cstr(env, argv[0], path, sizeof(path)) ||
        !inspect_cstr(env, argv[1], ceiling, sizeof(ceiling))) {
        return enif_make_badarg(env);
    }

    git_repository *repo = NULL;
    const char *ceiling_dirs = ceiling[0] ? ceiling : NULL;
    int error = git_repository_open_ext(&repo, path, 0, ceiling_dirs);
    if (error < 0) {
        return make_git_error(env, error, "open failed");
    }
    return wrap_repo(env, repo);
}

static ERL_NIF_TERM status_flag_to_atom(unsigned flags, int staged)
{
    if (flags & GIT_STATUS_CONFLICTED) {
        return ATOM_CONFLICTED;
    }
    if (staged) {
        if (flags & GIT_STATUS_INDEX_NEW) {
            return ATOM_NEW;
        }
        if (flags & GIT_STATUS_INDEX_MODIFIED) {
            return ATOM_MODIFIED;
        }
        if (flags & GIT_STATUS_INDEX_DELETED) {
            return ATOM_DELETED;
        }
        if (flags & GIT_STATUS_INDEX_RENAMED) {
            return ATOM_RENAMED;
        }
        if (flags & GIT_STATUS_INDEX_TYPECHANGE) {
            return ATOM_TYPECHANGE;
        }
        return ATOM_NIL;
    }
    if (flags & GIT_STATUS_IGNORED) {
        return ATOM_IGNORED;
    }
    if (flags & GIT_STATUS_WT_NEW) {
        return ATOM_NEW;
    }
    if (flags & GIT_STATUS_WT_MODIFIED) {
        return ATOM_MODIFIED;
    }
    if (flags & GIT_STATUS_WT_DELETED) {
        return ATOM_DELETED;
    }
    if (flags & GIT_STATUS_WT_RENAMED) {
        return ATOM_RENAMED;
    }
    if (flags & GIT_STATUS_WT_TYPECHANGE) {
        return ATOM_TYPECHANGE;
    }
    if (flags & GIT_STATUS_WT_UNREADABLE) {
        return ATOM_UNREADABLE;
    }
    return ATOM_NIL;
}

static const char *status_path(const git_status_entry *entry)
{
    if (entry->index_to_workdir) {
        if (entry->index_to_workdir->new_file.path) {
            return entry->index_to_workdir->new_file.path;
        }
        return entry->index_to_workdir->old_file.path;
    }
    if (entry->head_to_index) {
        if (entry->head_to_index->new_file.path) {
            return entry->head_to_index->new_file.path;
        }
        return entry->head_to_index->old_file.path;
    }
    return NULL;
}

static const char *status_old_path(const git_status_entry *entry)
{
    if ((entry->status & GIT_STATUS_INDEX_RENAMED) && entry->head_to_index) {
        return entry->head_to_index->old_file.path;
    }
    if ((entry->status & GIT_STATUS_WT_RENAMED) && entry->index_to_workdir) {
        return entry->index_to_workdir->old_file.path;
    }
    return NULL;
}

static ERL_NIF_TERM current_branch_term(ErlNifEnv *env, git_repository *repo)
{
    if (git_repository_head_unborn(repo) == 1) {
        return ATOM_UNBORN;
    }
    if (git_repository_head_detached(repo) == 1) {
        return ATOM_DETACHED;
    }

    git_reference *head = NULL;
    int error = git_repository_head(&head, repo);
    if (error < 0) {
        return ATOM_NIL;
    }
    const char *name = NULL;
    if (git_branch_name(&name, head) == 0 && name) {
        ERL_NIF_TERM term = make_binary(env, name);
        git_reference_free(head);
        return term;
    }
    const char *shorthand = git_reference_shorthand(head);
    ERL_NIF_TERM term = make_binary(env, shorthand ? shorthand : "");
    git_reference_free(head);
    return term;
}

static ERL_NIF_TERM nif_status(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ex_git_repo *r;
    if (!get_repo(env, argv[0], &r)) {
        return enif_make_badarg(env);
    }
    git_repository *repo = lock_repo(r);
    if (!repo) {
        return make_error_term(env, ATOM_CLOSED, "repository is closed");
    }

    git_status_options opts = GIT_STATUS_OPTIONS_INIT;
    opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED |
                 GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS |
                 GIT_STATUS_OPT_INCLUDE_IGNORED |
                 GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX |
                 GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR |
                 GIT_STATUS_OPT_EXCLUDE_SUBMODULES;

    git_status_list *list = NULL;
    int error = git_status_list_new(&list, repo, &opts);
    if (error < 0) {
        unlock_repo(r);
        return make_git_error(env, error, "status failed");
    }

    size_t count = git_status_list_entrycount(list);
    ERL_NIF_TERM entries = enif_make_list(env, 0);

    for (size_t i = count; i > 0; i--) {
        const git_status_entry *entry = git_status_byindex(list, i - 1);
        if (!entry || entry->status == GIT_STATUS_CURRENT) {
            continue;
        }
        const char *path = status_path(entry);
        if (!path) {
            continue;
        }

        ERL_NIF_TERM keys[4];
        ERL_NIF_TERM vals[4];
        unsigned n = 0;
        keys[n] = ATOM_PATH;
        vals[n] = make_binary(env, path);
        n++;
        keys[n] = ATOM_STAGED;
        vals[n] = status_flag_to_atom(entry->status, 1);
        n++;
        keys[n] = ATOM_UNSTAGED;
        vals[n] = status_flag_to_atom(entry->status, 0);
        n++;
        const char *old_path = status_old_path(entry);
        if (old_path) {
            keys[n] = ATOM_OLD_PATH;
            vals[n] = make_binary(env, old_path);
            n++;
        }
        ERL_NIF_TERM map;
        enif_make_map_from_arrays(env, keys, vals, n, &map);
        entries = enif_make_list_cell(env, map, entries);
    }

    ERL_NIF_TERM result;
    ERL_NIF_TERM rkeys[2] = {ATOM_BRANCH, ATOM_ENTRIES};
    ERL_NIF_TERM rvals[2] = {current_branch_term(env, repo), entries};
    enif_make_map_from_arrays(env, rkeys, rvals, 2, &result);

    git_status_list_free(list);
    unlock_repo(r);
    return make_ok(env, result);
}

static int peel_to_tree(git_repository *repo, const char *spec, git_tree **out)
{
    git_object *obj = NULL;
    int error = git_revparse_single(&obj, repo, spec);
    if (error < 0) {
        return error;
    }
    git_object *tree_obj = NULL;
    error = git_object_peel(&tree_obj, obj, GIT_OBJECT_TREE);
    git_object_free(obj);
    if (error < 0) {
        return error;
    }
    *out = (git_tree *)tree_obj;
    return 0;
}

static ERL_NIF_TERM nif_diff(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ex_git_repo *r;
    int mode = 0;
    if (!get_repo(env, argv[0], &r) || !enif_get_int(env, argv[1], &mode)) {
        return enif_make_badarg(env);
    }

    git_repository *repo = lock_repo(r);
    if (!repo) {
        return make_error_term(env, ATOM_CLOSED, "repository is closed");
    }

    git_diff_options opts = GIT_DIFF_OPTIONS_INIT;
    git_diff *diff = NULL;
    git_tree *from_tree = NULL;
    git_tree *to_tree = NULL;
    int error = 0;

    if (mode == 3) {
        char from_spec[PATH_BUFSZ];
        char to_spec[PATH_BUFSZ];
        if (!inspect_cstr(env, argv[2], from_spec, sizeof(from_spec)) ||
            !inspect_cstr(env, argv[3], to_spec, sizeof(to_spec))) {
            unlock_repo(r);
            return enif_make_badarg(env);
        }
        error = peel_to_tree(repo, from_spec, &from_tree);
        if (error == 0) {
            error = peel_to_tree(repo, to_spec, &to_tree);
        }
        if (error == 0) {
            error = git_diff_tree_to_tree(&diff, repo, from_tree, to_tree, &opts);
        }
    } else if (mode == 1) {
        error = git_diff_index_to_workdir(&diff, repo, NULL, &opts);
    } else if (mode == 2) {
        if (git_repository_head_unborn(repo) == 1) {
            error = git_diff_tree_to_index(&diff, repo, NULL, NULL, &opts);
        } else {
            error = peel_to_tree(repo, "HEAD", &from_tree);
            if (error == 0) {
                error = git_diff_tree_to_index(&diff, repo, from_tree, NULL, &opts);
            }
        }
    } else {
        if (git_repository_head_unborn(repo) == 1) {
            error = git_diff_tree_to_workdir_with_index(&diff, repo, NULL, &opts);
        } else {
            error = peel_to_tree(repo, "HEAD", &from_tree);
            if (error == 0) {
                error = git_diff_tree_to_workdir_with_index(&diff, repo, from_tree, &opts);
            }
        }
    }

    if (from_tree) {
        git_tree_free(from_tree);
    }
    if (to_tree) {
        git_tree_free(to_tree);
    }

    if (error < 0) {
        unlock_repo(r);
        return make_git_error(env, error, "diff failed");
    }

    git_buf buf = GIT_BUF_INIT;
    error = git_diff_to_buf(&buf, diff, GIT_DIFF_FORMAT_PATCH);
    git_diff_free(diff);
    if (error < 0) {
        git_buf_dispose(&buf);
        unlock_repo(r);
        return make_git_error(env, error, "diff format failed");
    }

    ERL_NIF_TERM patch = make_binary_n(env, buf.ptr ? buf.ptr : "", buf.size);
    git_buf_dispose(&buf);
    unlock_repo(r);
    return make_ok(env, patch);
}

static ERL_NIF_TERM nif_add(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ex_git_repo *r;
    if (!get_repo(env, argv[0], &r)) {
        return enif_make_badarg(env);
    }

    git_strarray paths = {0};
    if (!list_to_strarray(env, argv[1], &paths)) {
        return enif_make_badarg(env);
    }

    char *dot = ".";
    git_strarray fallback = {0};
    git_strarray *use = &paths;
    if (paths.count == 0) {
        fallback.strings = &dot;
        fallback.count = 1;
        use = &fallback;
    }

    git_repository *repo = lock_repo(r);
    if (!repo) {
        free_strarray(&paths);
        return make_error_term(env, ATOM_CLOSED, "repository is closed");
    }

    git_index *index = NULL;
    int error = git_repository_index(&index, repo);
    if (error == 0) {
        error = git_index_add_all(index, use, GIT_INDEX_ADD_DEFAULT, NULL, NULL);
    }
    if (error == 0) {
        error = git_index_write(index);
    }
    if (index) {
        git_index_free(index);
    }
    unlock_repo(r);
    free_strarray(&paths);

    if (error < 0) {
        return make_git_error(env, error, "add failed");
    }
    return ATOM_OK;
}

static ERL_NIF_TERM nif_reset(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ex_git_repo *r;
    int type = 0;
    if (!get_repo(env, argv[0], &r) || !enif_get_int(env, argv[1], &type)) {
        return enif_make_badarg(env);
    }

    char target[PATH_BUFSZ];
    if (!inspect_cstr(env, argv[2], target, sizeof(target))) {
        return enif_make_badarg(env);
    }
    if (target[0] == 0) {
        memcpy(target, "HEAD", 5);
    }

    git_strarray paths = {0};
    if (!list_to_strarray(env, argv[3], &paths)) {
        return enif_make_badarg(env);
    }

    git_repository *repo = lock_repo(r);
    if (!repo) {
        free_strarray(&paths);
        return make_error_term(env, ATOM_CLOSED, "repository is closed");
    }

    git_object *obj = NULL;
    int error = git_revparse_single(&obj, repo, target);
    if (error < 0) {
        unlock_repo(r);
        free_strarray(&paths);
        return make_git_error(env, error, "reset target not found");
    }

    if (type == 3) {
        error = git_reset_default(repo, obj, &paths);
    } else {
        git_reset_t reset_type = GIT_RESET_MIXED;
        if (type == 1) {
            reset_type = GIT_RESET_HARD;
        } else if (type == 2) {
            reset_type = GIT_RESET_SOFT;
        }
        error = git_reset(repo, obj, reset_type, NULL);
    }

    git_object_free(obj);
    unlock_repo(r);
    free_strarray(&paths);

    if (error < 0) {
        return make_git_error(env, error, "reset failed");
    }
    return ATOM_OK;
}

static int tree_equals_parent(git_repository *repo, git_index *index, git_commit *parent)
{
    git_oid tree_oid;
    if (git_index_write_tree(&tree_oid, index) < 0) {
        return 0;
    }
    if (!parent) {
        git_tree *tree = NULL;
        if (git_tree_lookup(&tree, repo, &tree_oid) < 0) {
            return 0;
        }
        int empty = git_tree_entrycount(tree) == 0;
        git_tree_free(tree);
        return empty;
    }
    git_tree *parent_tree = NULL;
    if (git_commit_tree(&parent_tree, parent) < 0) {
        return 0;
    }
    int same = git_oid_equal(&tree_oid, git_tree_id(parent_tree));
    git_tree_free(parent_tree);
    return same;
}

static ERL_NIF_TERM nif_commit(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ex_git_repo *r;
    if (!get_repo(env, argv[0], &r)) {
        return enif_make_badarg(env);
    }

    char *message = dup_cstr(env, argv[1]);
    char *name = dup_cstr(env, argv[2]);
    char *email = dup_cstr(env, argv[3]);
    if (!message || !name || !email) {
        enif_free(message);
        enif_free(name);
        enif_free(email);
        return enif_make_badarg(env);
    }

    git_repository *repo = lock_repo(r);
    if (!repo) {
        enif_free(message);
        enif_free(name);
        enif_free(email);
        return make_error_term(env, ATOM_CLOSED, "repository is closed");
    }

    git_index *index = NULL;
    git_signature *sig = NULL;
    git_tree *tree = NULL;
    git_reference *head_ref = NULL;
    git_commit *parent = NULL;
    git_oid tree_oid;
    git_oid commit_oid;
    int error = git_repository_index(&index, repo);
    if (error == 0) {
        error = git_index_write_tree(&tree_oid, index);
    }
    if (error == 0) {
        error = git_tree_lookup(&tree, repo, &tree_oid);
    }
    if (error == 0) {
        error = git_signature_now(&sig, name, email);
    }

    int unborn = git_repository_head_unborn(repo) == 1;
    if (error == 0 && !unborn) {
        error = git_repository_head(&head_ref, repo);
        if (error == 0) {
            error = git_commit_lookup(&parent, repo, git_reference_target(head_ref));
        }
    }

    if (error == 0 && tree_equals_parent(repo, index, parent)) {
        if (index) {
            git_index_free(index);
        }
        if (sig) {
            git_signature_free(sig);
        }
        if (tree) {
            git_tree_free(tree);
        }
        if (head_ref) {
            git_reference_free(head_ref);
        }
        if (parent) {
            git_commit_free(parent);
        }
        unlock_repo(r);
        enif_free(message);
        enif_free(name);
        enif_free(email);
        return make_error_term(env, ATOM_NOTHING_TO_COMMIT, "nothing to commit");
    }

    if (error == 0) {
        const git_commit *parents[1];
        int parent_count = 0;
        if (parent) {
            parents[0] = parent;
            parent_count = 1;
        }
        error = git_commit_create(&commit_oid, repo, "HEAD", sig, sig, NULL, message, tree,
                                  (size_t)parent_count, parent_count ? parents : NULL);
    }

    if (index) {
        git_index_free(index);
    }
    if (sig) {
        git_signature_free(sig);
    }
    if (tree) {
        git_tree_free(tree);
    }
    if (head_ref) {
        git_reference_free(head_ref);
    }
    if (parent) {
        git_commit_free(parent);
    }
    unlock_repo(r);
    enif_free(message);
    enif_free(name);
    enif_free(email);

    if (error < 0) {
        return make_git_error(env, error, "commit failed");
    }

    char hex[HEX_BUFSZ];
    git_oid_tostr(hex, sizeof(hex), &commit_oid);
    return make_ok(env, make_binary(env, hex));
}

static ERL_NIF_TERM commit_to_map(ErlNifEnv *env, git_commit *commit)
{
    char hex[HEX_BUFSZ];
    git_oid_tostr(hex, sizeof(hex), git_commit_id(commit));
    const git_signature *author = git_commit_author(commit);
    const char *message = git_commit_message(commit);
    const char *summary = git_commit_summary(commit);

    ERL_NIF_TERM author_map;
    ERL_NIF_TERM akeys[3] = {ATOM_NAME, ATOM_EMAIL, ATOM_TIME};
    ERL_NIF_TERM avals[3] = {
        make_binary(env, author ? author->name : ""),
        make_binary(env, author ? author->email : ""),
        enif_make_int64(env, author ? (ErlNifSInt64)author->when.time : 0)
    };
    enif_make_map_from_arrays(env, akeys, avals, 3, &author_map);

    ERL_NIF_TERM map;
    ERL_NIF_TERM keys[4] = {ATOM_OID, ATOM_MESSAGE, ATOM_SUMMARY, ATOM_AUTHOR};
    ERL_NIF_TERM vals[4] = {
        make_binary(env, hex),
        make_binary(env, message ? message : ""),
        make_binary(env, summary ? summary : ""),
        author_map
    };
    enif_make_map_from_arrays(env, keys, vals, 4, &map);
    return map;
}

static ERL_NIF_TERM nif_log(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ex_git_repo *r;
    int limit = 0;
    if (!get_repo(env, argv[0], &r) || !enif_get_int(env, argv[1], &limit)) {
        return enif_make_badarg(env);
    }
    if (limit <= 0) {
        limit = 32;
    }

    git_repository *repo = lock_repo(r);
    if (!repo) {
        return make_error_term(env, ATOM_CLOSED, "repository is closed");
    }

    if (git_repository_head_unborn(repo) == 1 || git_repository_is_empty(repo) == 1) {
        unlock_repo(r);
        return make_ok(env, enif_make_list(env, 0));
    }

    git_revwalk *walk = NULL;
    int error = git_revwalk_new(&walk, repo);
    if (error == 0) {
        git_revwalk_sorting(walk, GIT_SORT_TIME);
        error = git_revwalk_push_head(walk);
    }
    if (error < 0) {
        if (walk) {
            git_revwalk_free(walk);
        }
        unlock_repo(r);
        return make_git_error(env, error, "log failed");
    }

    ERL_NIF_TERM list = enif_make_list(env, 0);
    ERL_NIF_TERM acc[256];
    unsigned n = 0;
    git_oid oid;
    while (n < (unsigned)limit && n < 256 && git_revwalk_next(&oid, walk) == 0) {
        git_commit *commit = NULL;
        if (git_commit_lookup(&commit, repo, &oid) == 0) {
            acc[n++] = commit_to_map(env, commit);
            git_commit_free(commit);
        }
    }
    git_revwalk_free(walk);
    unlock_repo(r);

    list = enif_make_list_from_array(env, acc, n);
    return make_ok(env, list);
}

static ERL_NIF_TERM nif_branches(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ex_git_repo *r;
    if (!get_repo(env, argv[0], &r)) {
        return enif_make_badarg(env);
    }
    git_repository *repo = lock_repo(r);
    if (!repo) {
        return make_error_term(env, ATOM_CLOSED, "repository is closed");
    }

    git_branch_iterator *iter = NULL;
    int error = git_branch_iterator_new(&iter, repo, GIT_BRANCH_LOCAL);
    if (error < 0) {
        unlock_repo(r);
        return make_git_error(env, error, "branch list failed");
    }

    ERL_NIF_TERM acc[128];
    unsigned n = 0;
    git_reference *ref = NULL;
    git_branch_t btype;
    while (n < 128 && git_branch_next(&ref, &btype, iter) == 0) {
        const char *name = NULL;
        if (git_branch_name(&name, ref) == 0 && name) {
            ERL_NIF_TERM map;
            ERL_NIF_TERM keys[2] = {ATOM_NAME, ATOM_CURRENT};
            ERL_NIF_TERM vals[2] = {
                make_binary(env, name),
                git_branch_is_head(ref) ? ATOM_TRUE : ATOM_FALSE
            };
            enif_make_map_from_arrays(env, keys, vals, 2, &map);
            acc[n++] = map;
        }
        git_reference_free(ref);
    }
    git_branch_iterator_free(iter);
    unlock_repo(r);
    return make_ok(env, enif_make_list_from_array(env, acc, n));
}

static ERL_NIF_TERM nif_create_branch(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ex_git_repo *r;
    int force = 0;
    if (!get_repo(env, argv[0], &r) || !enif_get_int(env, argv[2], &force)) {
        return enif_make_badarg(env);
    }
    char name[PATH_BUFSZ];
    if (!inspect_cstr(env, argv[1], name, sizeof(name))) {
        return enif_make_badarg(env);
    }

    git_repository *repo = lock_repo(r);
    if (!repo) {
        return make_error_term(env, ATOM_CLOSED, "repository is closed");
    }

    git_reference *head = NULL;
    git_commit *commit = NULL;
    git_reference *branch = NULL;
    int error = git_repository_head(&head, repo);
    if (error == 0) {
        error = git_commit_lookup(&commit, repo, git_reference_target(head));
    }
    if (error == 0) {
        error = git_branch_create(&branch, repo, name, commit, force ? 1 : 0);
    }

    if (head) {
        git_reference_free(head);
    }
    if (commit) {
        git_commit_free(commit);
    }
    if (branch) {
        git_reference_free(branch);
    }
    unlock_repo(r);

    if (error < 0) {
        return make_git_error(env, error, "create branch failed");
    }
    return ATOM_OK;
}

static ERL_NIF_TERM nif_checkout(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ex_git_repo *r;
    int force = 0;
    if (!get_repo(env, argv[0], &r) || !enif_get_int(env, argv[2], &force)) {
        return enif_make_badarg(env);
    }
    char name[PATH_BUFSZ];
    if (!inspect_cstr(env, argv[1], name, sizeof(name))) {
        return enif_make_badarg(env);
    }

    git_repository *repo = lock_repo(r);
    if (!repo) {
        return make_error_term(env, ATOM_CLOSED, "repository is closed");
    }

    git_checkout_options opts = GIT_CHECKOUT_OPTIONS_INIT;
    opts.checkout_strategy = force ? GIT_CHECKOUT_FORCE : GIT_CHECKOUT_SAFE;

    git_reference *branch = NULL;
    git_object *obj = NULL;
    git_commit *commit = NULL;
    int error = git_branch_lookup(&branch, repo, name, GIT_BRANCH_LOCAL);
    if (error == 0) {
        error = git_commit_lookup(&commit, repo, git_reference_target(branch));
        if (error == 0) {
            error = git_checkout_tree(repo, (git_object *)commit, &opts);
        }
        if (error == 0) {
            char refname[PATH_BUFSZ];
            int written = snprintf(refname, sizeof(refname), "refs/heads/%s", name);
            if (written < 0 || (size_t)written >= sizeof(refname)) {
                error = GIT_EINVALIDSPEC;
            } else {
                error = git_repository_set_head(repo, refname);
            }
        }
    } else {
        error = git_revparse_single(&obj, repo, name);
        if (error == 0) {
            error = git_checkout_tree(repo, obj, &opts);
        }
        if (error == 0) {
            error = git_repository_set_head_detached(repo, git_object_id(obj));
        }
    }

    if (branch) {
        git_reference_free(branch);
    }
    if (commit) {
        git_commit_free(commit);
    }
    if (obj) {
        git_object_free(obj);
    }
    unlock_repo(r);

    if (error < 0) {
        return make_git_error(env, error, "checkout failed");
    }
    return ATOM_OK;
}

static ERL_NIF_TERM nif_workdir(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    ex_git_repo *r;
    if (!get_repo(env, argv[0], &r)) {
        return enif_make_badarg(env);
    }
    git_repository *repo = lock_repo(r);
    if (!repo) {
        return make_error_term(env, ATOM_CLOSED, "repository is closed");
    }
    const char *workdir = git_repository_workdir(repo);
    ERL_NIF_TERM term = make_binary(env, workdir ? workdir : "");
    unlock_repo(r);
    return make_ok(env, term);
}

static ErlNifFunc nif_funcs[] = {
    {"loaded", 0, nif_loaded, 0},
    {"init", 1, nif_repo_init, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"open", 2, nif_open, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"status", 1, nif_status, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"diff", 4, nif_diff, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"add", 2, nif_add, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"reset", 4, nif_reset, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"commit", 4, nif_commit, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"log", 2, nif_log, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"branches", 1, nif_branches, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"create_branch", 3, nif_create_branch, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"checkout", 3, nif_checkout, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"workdir", 1, nif_workdir, ERL_NIF_DIRTY_JOB_IO_BOUND}
};

static int on_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    (void)priv_data;
    (void)load_info;

    ATOM_OK = enif_make_atom(env, "ok");
    ATOM_ERROR = enif_make_atom(env, "error");
    ATOM_NIL = enif_make_atom(env, "nil");
    ATOM_TRUE = enif_make_atom(env, "true");
    ATOM_FALSE = enif_make_atom(env, "false");
    ATOM_NEW = enif_make_atom(env, "new");
    ATOM_MODIFIED = enif_make_atom(env, "modified");
    ATOM_DELETED = enif_make_atom(env, "deleted");
    ATOM_RENAMED = enif_make_atom(env, "renamed");
    ATOM_TYPECHANGE = enif_make_atom(env, "typechange");
    ATOM_CONFLICTED = enif_make_atom(env, "conflicted");
    ATOM_IGNORED = enif_make_atom(env, "ignored");
    ATOM_UNREADABLE = enif_make_atom(env, "unreadable");
    ATOM_PATH = enif_make_atom(env, "path");
    ATOM_STAGED = enif_make_atom(env, "staged");
    ATOM_UNSTAGED = enif_make_atom(env, "unstaged");
    ATOM_OLD_PATH = enif_make_atom(env, "old_path");
    ATOM_BRANCH = enif_make_atom(env, "branch");
    ATOM_ENTRIES = enif_make_atom(env, "entries");
    ATOM_NAME = enif_make_atom(env, "name");
    ATOM_CURRENT = enif_make_atom(env, "current?");
    ATOM_OID = enif_make_atom(env, "oid");
    ATOM_MESSAGE = enif_make_atom(env, "message");
    ATOM_SUMMARY = enif_make_atom(env, "summary");
    ATOM_AUTHOR = enif_make_atom(env, "author");
    ATOM_EMAIL = enif_make_atom(env, "email");
    ATOM_TIME = enif_make_atom(env, "time");
    ATOM_UNBORN = enif_make_atom(env, "unborn");
    ATOM_DETACHED = enif_make_atom(env, "detached");
    ATOM_NOT_FOUND = enif_make_atom(env, "not_found");
    ATOM_INVALID = enif_make_atom(env, "invalid");
    ATOM_CONFLICT = enif_make_atom(env, "conflict");
    ATOM_LOCKED = enif_make_atom(env, "locked");
    ATOM_NOTHING_TO_COMMIT = enif_make_atom(env, "nothing_to_commit");
    ATOM_CLOSED = enif_make_atom(env, "closed");
    ATOM_NOMEM = enif_make_atom(env, "enomem");

    LOCK_TABLE_MUTEX = enif_mutex_create("ex_git_lock_table");
    if (!LOCK_TABLE_MUTEX) {
        return -1;
    }

    ErlNifResourceTypeInit init;
    memset(&init, 0, sizeof(init));
    init.dtor = repo_dtor;
    init.down = repo_down;
    REPO_RESOURCE = enif_open_resource_type_x(
        env,
        "ex_git_repo",
        &init,
        (ErlNifResourceFlags)(ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER),
        NULL);
    if (!REPO_RESOURCE) {
        return -1;
    }

    git_libgit2_init();
    return 0;
}

static void on_unload(ErlNifEnv *env, void *priv_data)
{
    (void)env;
    (void)priv_data;
    git_libgit2_shutdown();
    if (LOCK_TABLE_MUTEX) {
        enif_mutex_destroy(LOCK_TABLE_MUTEX);
        LOCK_TABLE_MUTEX = NULL;
    }
}

ERL_NIF_INIT(Elixir.ExGit.NIF, nif_funcs, on_load, NULL, NULL, on_unload)
