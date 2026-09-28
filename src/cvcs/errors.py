class CVCSError(Exception):
    """Base error for failures that should be shown directly to a user."""


class NotARepositoryError(CVCSError):
    pass


class IntegrityError(CVCSError):
    pass


class ConflictError(CVCSError):
    pass

