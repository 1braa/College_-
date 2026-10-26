#!/usr/bin/env python3
"""Оконная версия приложения «Колледж» (tkinter, входит в состав Python)."""
import tkinter as tk
from tkinter import ttk, messagebox
import psycopg2
from psycopg2 import errors

from college_app import CollegeDB, DSN, MENU, parse_date


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Колледж: студенты, группы, оценки")
        self.geometry("980x620")
        self.minsize(860, 520)
        self.db = None
        try:
            self.db = CollegeDB(DSN)
        except psycopg2.OperationalError as e:
            messagebox.showerror("Нет подключения", "Не удалось подключиться к БД:\n" + str(e).strip())
            self.destroy()
            return
        self.login_screen()

    # ---------- вспомогательные ----------
    def clear(self):
        for w in self.winfo_children():
            w.destroy()

    def guard(self, action, ok_message=None):
        """Выполняет действие; ошибки БД показываются окном, транзакция откатывается."""
        try:
            result = action()
            if ok_message:
                messagebox.showinfo("Готово", ok_message)
            return result
        except ValueError as e:
            self.db.conn.rollback()
            messagebox.showwarning("Ошибка ввода", str(e))
        except errors.InsufficientPrivilege:
            self.db.conn.rollback()
            messagebox.showerror("Отказано в доступе", "У вашей роли нет прав на эту операцию")
        except psycopg2.Error as e:
            self.db.conn.rollback()
            messagebox.showerror("Ошибка БД", (e.diag.message_primary or str(e)).strip())
        return None

    @staticmethod
    def fill(tree, cols, rows):
        tree.delete(*tree.get_children())
        tree["columns"] = cols
        for c in cols:
            tree.heading(c, text=c)
            tree.column(c, width=max(90, 880 // max(1, len(cols))), anchor="w")
        for r in rows:
            tree.insert("", "end", values=["" if v is None else v for v in r])

    @staticmethod
    def table(parent):
        frame = ttk.Frame(parent)
        tree = ttk.Treeview(frame, show="headings", height=12)
        sb = ttk.Scrollbar(frame, orient="vertical", command=tree.yview)
        tree.configure(yscrollcommand=sb.set)
        tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        return frame, tree

    @staticmethod
    def field(parent, label, row, default=""):
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", padx=4, pady=3)
        var = tk.StringVar(value=default)
        ttk.Entry(parent, textvariable=var, width=34).grid(row=row, column=1, sticky="w", padx=4, pady=3)
        return var

    # ---------- вход ----------
    def login_screen(self):
        self.clear()
        box = ttk.Frame(self, padding=30)
        box.place(relx=0.5, rely=0.4, anchor="center")
        ttk.Label(box, text="Колледж", font=("Arial", 22, "bold")).grid(row=0, column=0, columnspan=2, pady=(0, 14))
        user = self.field(box, "Логин", 1)
        ttk.Label(box, text="Пароль").grid(row=2, column=0, sticky="w", padx=4, pady=3)
        pwd = tk.StringVar()
        entry = ttk.Entry(box, textvariable=pwd, show="*", width=34)
        entry.grid(row=2, column=1, padx=4, pady=3)
        msg = ttk.Label(box, text="", foreground="#B00020")
        msg.grid(row=4, column=0, columnspan=2)
        attempts = {"n": 0}

        def do_login(_=None):
            def act():
                return self.db.login(user.get().strip(), pwd.get())
            ok = self.guard(act)
            if ok:
                self.main_screen()
                return
            if ok is False:
                attempts["n"] += 1
                msg.config(text="Неверный логин или пароль")
                if attempts["n"] >= 3:
                    messagebox.showerror("Вход", "Слишком много неудачных попыток")
                    self.destroy()
        ttk.Button(box, text="Войти", command=do_login).grid(row=3, column=0, columnspan=2, pady=10)
        self.bind("<Return>", do_login)

    # ---------- главное окно ----------
    def main_screen(self):
        self.unbind("<Return>")
        self.clear()
        allowed = set(MENU[self.db.role])
        top = ttk.Frame(self, padding=(10, 6))
        top.pack(fill="x")
        ttk.Label(top, text=f"Пользователь: {self.db.username}   |   роль: {self.db.role}").pack(side="left")
        ttk.Button(top, text="Выход", command=self.destroy).pack(side="right")
        nb = ttk.Notebook(self)
        nb.pack(fill="both", expand=True, padx=8, pady=6)

        if "1" in allowed:
            self.tab_students(nb, allowed)
        if "2" in allowed:
            self.tab_add_student(nb)
        if "5" in allowed:
            self.tab_grade(nb)
        if "6" in allowed:
            self.tab_report(nb)
        if "7" in allowed:
            self.tab_schedule(nb)
        if "8" in allowed or "9" in allowed:
            self.tab_admin(nb, allowed)

    def tab_students(self, nb, allowed):
        tab = ttk.Frame(nb, padding=8)
        nb.add(tab, text="Студенты")
        bar = ttk.Frame(tab)
        bar.pack(fill="x")
        grp = tk.StringVar(value="П1-24")
        ttk.Label(bar, text="Группа:").pack(side="left")
        ttk.Entry(bar, textvariable=grp, width=12).pack(side="left", padx=6)
        frame, tree = self.table(tab)
        frame.pack(fill="both", expand=True, pady=8)

        def show():
            res = self.guard(lambda: self.db.students_of_group(grp.get().strip()))
            if res:
                self.fill(tree, *res)
        ttk.Button(bar, text="Показать", command=show).pack(side="left")
        if not ({"3", "4"} & allowed):
            return
        edit = ttk.LabelFrame(tab, text="Изменение выбранного студента", padding=8)
        edit.pack(fill="x")
        sid, phone, new_group = (self.field(edit, "id студента", 0), self.field(edit, "Новый телефон", 1),
                                 self.field(edit, "id новой группы", 2))
        status = tk.StringVar(value="1")
        ttk.Label(edit, text="Статус").grid(row=3, column=0, sticky="w", padx=4)
        ttk.Combobox(edit, textvariable=status, values=["1", "2", "3"], width=5, state="readonly").grid(row=3, column=1, sticky="w", padx=4)
        ttk.Label(edit, text="1 — учится, 2 — академ. отпуск, 3 — отчислен").grid(row=3, column=1, padx=70, sticky="w")

        def on_select(_):
            sel = tree.selection()
            if sel:
                sid.set(tree.item(sel[0])["values"][0])
        tree.bind("<<TreeviewSelect>>", on_select)

        def commit(fn, ok):
            if self.guard(lambda: (fn(), self.db.conn.commit()), ok) is not None:
                show()

        btns = ttk.Frame(edit)
        btns.grid(row=0, column=2, rowspan=4, padx=20)
        ttk.Button(btns, text="Изменить телефон", command=lambda: commit(
            lambda: self.db.update_phone(int(sid.get()), phone.get().strip()), "Телефон обновлён")).pack(fill="x", pady=2)
        ttk.Button(btns, text="Перевести в группу", command=lambda: commit(
            lambda: self.db.transfer(int(sid.get()), int(new_group.get())), "Студент переведён")).pack(fill="x", pady=2)
        ttk.Button(btns, text="Сменить статус", command=lambda: commit(
            lambda: self.db.change_status(int(sid.get()), int(status.get())), "Статус изменён")).pack(fill="x", pady=2)

    def tab_add_student(self, nb):
        tab = ttk.Frame(nb, padding=14)
        nb.add(tab, text="Добавить студента")
        v = [self.field(tab, "Фамилия", 0), self.field(tab, "Имя", 1), self.field(tab, "Отчество", 2),
             self.field(tab, "Дата рождения (ГГГГ-ММ-ДД)", 3, "2007-01-01"), self.field(tab, "Пол (М/Ж)", 4),
             self.field(tab, "E-mail", 5), self.field(tab, "Группа", 6)]

        def add():
            def act():
                last, first, mid, birth, gender, email, grp = (x.get().strip() for x in v)
                sid = self.db.add_student(last, first, mid, parse_date(birth), gender.upper(), email, grp)
                self.db.conn.commit()
                return sid
            sid = self.guard(act)
            if sid:
                messagebox.showinfo("Готово", f"Студент добавлен, id = {sid}")
        ttk.Button(tab, text="Добавить", command=add).grid(row=7, column=1, sticky="w", pady=12, padx=4)

    def tab_grade(self, nb):
        tab = ttk.Frame(nb, padding=14)
        nb.add(tab, text="Оценки")
        sid, lid = self.field(tab, "id студента", 0), self.field(tab, "id занятия", 1)
        val = tk.StringVar(value="5")
        ttk.Label(tab, text="Оценка").grid(row=2, column=0, sticky="w", padx=4, pady=3)
        ttk.Combobox(tab, textvariable=val, values=["2", "3", "4", "5", "6"], width=5).grid(row=2, column=1, sticky="w", padx=4)

        def save():
            self.guard(lambda: (self.db.add_grade(int(sid.get()), int(lid.get()), int(val.get())),
                                self.db.conn.commit()), "Оценка сохранена")
        ttk.Button(tab, text="Выставить", command=save).grid(row=3, column=1, sticky="w", pady=12, padx=4)

    def tab_report(self, nb):
        tab = ttk.Frame(nb, padding=8)
        nb.add(tab, text="Успеваемость группы")
        bar = ttk.Frame(tab)
        bar.pack(fill="x")
        grp = tk.StringVar(value="П1-24")
        ttk.Label(bar, text="Группа:").pack(side="left")
        ttk.Entry(bar, textvariable=grp, width=12).pack(side="left", padx=6)
        frame, tree = self.table(tab)
        frame.pack(fill="both", expand=True, pady=8)
        ttk.Button(bar, text="Сформировать", command=lambda: self.fill(tree, *(self.guard(
            lambda: self.db.group_report(grp.get().strip())) or ([], [])))).pack(side="left")

    def tab_schedule(self, nb):
        tab = ttk.Frame(nb, padding=8)
        nb.add(tab, text="Расписание")
        bar = ttk.Frame(tab)
        bar.pack(fill="x")
        grp, day = tk.StringVar(value="П1-24"), tk.StringVar(value="2026-09-14")
        for label, var, w in (("Группа:", grp, 12), ("Дата:", day, 14)):
            ttk.Label(bar, text=label).pack(side="left", padx=(8, 0))
            ttk.Entry(bar, textvariable=var, width=w).pack(side="left", padx=6)
        frame, tree = self.table(tab)
        frame.pack(fill="both", expand=True, pady=8)
        ttk.Button(bar, text="Показать", command=lambda: self.fill(tree, *(self.guard(
            lambda: self.db.schedule(grp.get().strip(), parse_date(day.get().strip()))) or ([], [])))).pack(side="left")

    def tab_admin(self, nb, allowed):
        tab = ttk.Frame(nb, padding=8)
        nb.add(tab, text="Администрирование")
        if "8" in allowed:
            box = ttk.LabelFrame(tab, text="Удаление занятия (оценки и посещаемость удаляются каскадно)", padding=8)
            box.pack(fill="x")
            lid = self.field(box, "id занятия", 0)

            def delete():
                if messagebox.askyesno("Подтверждение", "Удалить занятие и связанные оценки?"):
                    self.guard(lambda: (self.db.delete_lesson(int(lid.get())), self.db.conn.commit()), "Занятие удалено")
            ttk.Button(box, text="Удалить", command=delete).grid(row=0, column=2, padx=10)
        if "9" in allowed:
            frame, tree = self.table(tab)
            frame.pack(fill="both", expand=True, pady=8)
            refresh = lambda: self.fill(tree, *(self.guard(lambda: self.db.audit_tail(30)) or ([], [])))
            ttk.Button(tab, text="Обновить журнал аудита", command=refresh).pack(anchor="w")
            refresh()


if __name__ == "__main__":
    App().mainloop()
