#!/bin/bash

# Функция для запроса подтверждения с правильной обработкой
ask_confirmation() {
    local prompt="$1"

    while true; do
        read -p "$prompt" -r response
        case $response in
            [Yy]|Yes|yes|YES|"")
                return 0  # Да (пустой ввод = да)
                ;;
            [Nn]|No|no|NO)
                return 1  # Нет
                ;;
            *)
                echo "Пожалуйста, введите 'y' (да) или 'n' (нет)."
                ;;
        esac
    done
}

# Функция для изменения pacman.conf
modify_pacman_conf() {
    local action="$1"  # "enable" или "disable"

    echo "Изменяем pacman.conf ($action)..."

    if [ "$action" = "enable" ]; then
        # Заменяем Required DatabaseOptional на TrustAll для установки
        run_sudo sed -i 's/Required DatabaseOptional/TrustAll/g' /etc/pacman.conf
        echo "Режим установки: TrustAll активирован в pacman.conf"
    else
        # Заменяем обратно TrustAll на Required DatabaseOptional
        run_sudo sed -i 's/TrustAll/Required DatabaseOptional/g' /etc/pacman.conf
        echo "Режим удаления: Required DatabaseOptional восстановлен в pacman.conf"
    fi
}

# Функция для создания сервиса assistant-resume
create_assistant_resume_service() {
    echo "Создаем сервис assistant-resume..."

    # Создаем файл сервиса
    cat << EOF | run_sudo tee /etc/systemd/system/assistant-resume.service > /dev/null
[Unit]
Description=Restart Assistant after sleep
After=sleep.target
After=suspend.target
After=hibernate.target
After=hybrid-sleep.target
Requires=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart assistant.service

[Install]
WantedBy=sleep.target
WantedBy=suspend.target
WantedBy=hybrid-sleep.target
WantedBy=hibernate.target
EOF

    # Даем правильные права на файл
    run_sudo chmod 644 /etc/systemd/system/assistant-resume.service

    # Включаем и запускаем сервис
    run_sudo systemctl daemon-reload
    run_sudo systemctl enable assistant-resume.service

    if [ $? -eq 0 ]; then
        echo "Сервис assistant-resume успешно создан и запущен"
    else
        echo "Предупреждение: не удалось запустить сервис assistant-resume"
    fi
}

# Функция для удаления сервиса assistant-resume
remove_assistant_resume_service() {
    echo "Удаляем сервис assistant-resume..."

    # Останавливаем и отключаем сервис
    run_sudo systemctl stop assistant-resume.service 2>/dev/null
    run_sudo systemctl disable assistant-resume.service 2>/dev/null

    # Удаляем файл сервиса
    if [ -f "/etc/systemd/system/assistant-resume.service" ]; then
        run_sudo rm -f /etc/systemd/system/assistant-resume.service
        echo "Файл сервиса assistant-resume удален"
    fi

    # Перезагружаем systemd
    run_sudo systemctl daemon-reload
}

# Запрашиваем sudo пароль и проверяем его правильность
while true; do
    echo "Введите ваш sudo пароль:"
    read -s SUDO_PASSWORD

    # Проверяем, введен ли пароль
    if [ -z "$SUDO_PASSWORD" ]; then
        echo "Ошибка: Пароль не может быть пустым. Попробуйте снова."
        continue
    fi

    # Проверяем правильность пароля
    echo "$SUDO_PASSWORD" | sudo -S true 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "Пароль принят."
        break
    else
        echo "Ошибка: Неверный пароль. Попробуйте снова."
    fi
done

# Функция для выполнения команд с sudo
run_sudo() {
    echo "$SUDO_PASSWORD" | sudo -S "$@"
}

# Проверяем наличие папки /opt/assistant
if [ -d "/opt/assistant" ]; then
    echo "Программа Assistant обнаружена. Выполняем удаление..."

    # Отключаем защиту от записи для удаления
    echo "Отключаем steamos-readonly..."
    run_sudo steamos-readonly disable
    if [ $? -ne 0 ]; then
        echo "Предупреждение: Не удалось отключить steamos-readonly"
    fi

    # Восстанавливаем оригинальные настройки pacman.conf
    modify_pacman_conf "disable"

    # Удаляем сервис assistant-resume
    remove_assistant_resume_service

    # Удаляем gtk2
    echo "Удаляем gtk2..."
    run_sudo pacman -R --noconfirm gtk2

    # Удаляем файл assistant.desktop из папки приложений
    DESKTOP_FILE="/home/deck/.local/share/applications/assistant.desktop"
    if [ -f "$DESKTOP_FILE" ]; then
        echo "Удаляем файл ярлыка из меню приложений..."
        rm -f "$DESKTOP_FILE"
        if [ $? -eq 0 ]; then
            echo "Файл assistant.desktop успешно удален из меню приложений."
        else
            echo "Не удалось удалить файл assistant.desktop."
        fi
    else
        echo "Файл assistant.desktop не найден в меню приложений."
    fi

    # Переходим в папку assistant и запускаем деинсталлятор, если он существует
    if [ -f "/opt/assistant/uninstall.sh" ]; then
        echo "Запускаем скрипт удаления..."
        cd /opt/assistant

        # Проверяем, есть ли у нас права на выполнение
        if [ ! -x "./uninstall.sh" ]; then
            sudo chmod +x ./uninstall.sh
        fi

        # Запускаем скрипт удаления и ждем его завершения
        echo "========================================="
        echo "ЗАПУСК СКРИПТА УДАЛЕНИЯ"
        echo "Скрипт будет запрашивать подтверждение."
        echo "Обязательно нужно поставить y или n."
        echo "Enter с пустым полем не работет."
        echo "========================================="
        sudo ./uninstall.sh
        UNINSTALL_RESULT=$?

        if [ $UNINSTALL_RESULT -eq 0 ]; then
            echo "Скрипт удаления выполнен успешно."
        else
            echo "Скрипт удаления завершился с ошибкой код: $UNINSTALL_RESULT"
        fi
    else
        echo "Скрипт удаления не найден."
    fi

    # Проверяем, существует ли еще папка assistant после uninstall.sh
    # и удаляем её автоматически без вопросов
    if [ -d "/opt/assistant" ]; then
        echo "Папка /opt/assistant все еще существует. Удаляем..."
        cd /opt
        run_sudo rm -rf assistant
        echo "Папка /opt/assistant удалена."
    else
        echo "Папка /opt/assistant уже удалена скриптом uninstall.sh."
    fi

    # Включаем защиту от записи
    echo "Включаем steamos-readonly..."
    run_sudo steamos-readonly enable
    if [ $? -ne 0 ]; then
        echo "Предупреждение: Не удалось включить steamos-readonly"
    fi

    echo "Удаление завершено!"

else
    echo "Программа Assistant не установлена. Выполняем установку..."

    # Проверяем наличие файла assistant.run в папке Downloads
    DOWNLOAD_PATH="/home/deck/Downloads/assistant.run"

    if [ -f "$DOWNLOAD_PATH" ]; then
        echo "Файл assistant.run уже существует в папке Downloads."
        if ask_confirmation "Использовать существующий файл? (y/n): "; then
            echo "Используем существующий файл: $DOWNLOAD_PATH"
        else
            # Скачиваем новый файл
            echo "Скачиваем новый файл..."
            DOWNLOAD_URL="https://xn--80akicokc0aablc.xn--p1ai/%D1%81%D0%BA%D0%B0%D1%87%D0%B0%D1%82%D1%8C/Download/1378"

            wget "$DOWNLOAD_URL" -O "$DOWNLOAD_PATH"
            if [ $? -ne 0 ]; then
                echo "Ошибка при скачивании файла. Проверьте ссылку и интернет-соединение."
                SUDO_PASSWORD=""
                exit 1
            fi

            # Проверяем, скачался ли файл
            if [ ! -f "$DOWNLOAD_PATH" ]; then
                echo "Ошибка: Файл не был скачан."
                SUDO_PASSWORD=""
                exit 1
            fi
            echo "Новый файл успешно скачан: $DOWNLOAD_PATH"
        fi
    else
        # Скачиваем файл
        echo "Скачиваем файл..."
        DOWNLOAD_URL="https://xn--80akicokc0aablc.xn--p1ai/%D1%81%D0%BA%D0%B0%D1%87%D0%B0%D1%82%D1%8C/Download/1378"

        wget "$DOWNLOAD_URL" -O "$DOWNLOAD_PATH"
        if [ $? -ne 0 ]; then
            echo "Ошибка при скачивании файла. Проверьте ссылку и интернет-соединение."
            SUDO_PASSWORD=""
            exit 1
        fi

        # Проверяем, скачался ли файл
        if [ ! -f "$DOWNLOAD_PATH" ]; then
            echo "Ошибка: Файл не был скачан."
            SUDO_PASSWORD=""
            exit 1
        fi
        echo "Файл успешно скачан: $DOWNLOAD_PATH"
    fi

    # Переходим в папку Downloads
    cd /home/deck/Downloads/ || {
        echo "Ошибка: Не удалось перейти в /home/deck/Downloads/"
        SUDO_PASSWORD=""
        exit 1
    }

    # Отключаем защиту от записи
    echo "Отключаем steamos-readonly..."
    run_sudo steamos-readonly disable
    if [ $? -ne 0 ]; then
        echo "Предупреждение: Не удалось отключить steamos-readonly"
    fi

    # Даем права на выполнение и запускаем установщик
    echo "Запускаем установщик..."
    run_sudo chmod +x assistant.run

    echo "========================================="
    echo "ЗАПУСК УСТАНОВЩИКА"
    echo "Установщик может запрашивать подтверждение"
    echo "========================================="

    # Запускаем установщик напрямую с sudo для интерактивного режима
    sudo ./assistant.run

    # Проверяем результат установки
    if [ $? -ne 0 ]; then
        echo "Предупреждение: Возникли проблемы при запуске установщика"
        if ask_confirmation "Продолжить установку пакетов? (y/n): "; then
            echo "Продолжаем установку пакетов..."
        else
            echo "Установка прервана пользователем."
            # Восстанавливаем pacman.conf перед выходом
            modify_pacman_conf "disable"
            # Включаем защиту от записи перед выходом
            run_sudo steamos-readonly enable
            SUDO_PASSWORD=""
            exit 1
        fi
    fi

    # Меняем настройки pacman.conf для установки
    modify_pacman_conf "enable"

    # Инициализируем ключи pacman
    echo "Инициализируем ключи pacman..."
    run_sudo pacman-key --init
    run_sudo pacman-key --populate archlinux

    # Обновляем базу данных pacman
    echo "Обновляем базу данных pacman..."
    run_sudo pacman -Sy --noconfirm

    # Устанавливаем gtk2 с автоматическим подтверждением
    echo "Устанавливаем gtk2..."
    run_sudo pacman -S --noconfirm gtk2

    if [ $? -eq 0 ]; then
        echo "gtk2 успешно установлен."
    else
        echo "Ошибка при установке gtk2."
    fi

    # Восстанавливаем оригинальные настройки pacman.conf после установки
    modify_pacman_conf "disable"

    # Создаем сервис assistant-resume
    create_assistant_resume_service

    # Копируем файл assistant.desktop с рабочего стола в папку приложений
    DESKTOP_SOURCE="/home/deck/Desktop/assistant.desktop"
    DESKTOP_DEST="/home/deck/.local/share/applications/assistant.desktop"

    if [ -f "$DESKTOP_SOURCE" ]; then
        echo "Копируем файл ярлыка в меню приложений..."
        cp "$DESKTOP_SOURCE" "$DESKTOP_DEST"
        if [ $? -eq 0 ]; then
            echo "Файл assistant.desktop успешно скопирован в меню приложений."

            # Даем права на выполнение
            chmod +x "$DESKTOP_DEST"
            echo "Права на выполнение установлены для файла ярлыка."
        else
            echo "Ошибка при копировании файла assistant.desktop."
        fi
    else
        echo "Файл assistant.desktop не найден на рабочем столе."
        echo "Проверьте путь: $DESKTOP_SOURCE"
    fi

    # УДАЛЯЕМ ФАЙЛ УСТАНОВЩИКА ПОСЛЕ УСТАНОВКИ
    echo "Удаляем файл установщика..."
    if [ -f "assistant.run" ]; then
        rm -f assistant.run
        if [ $? -eq 0 ]; then
            echo "Файл assistant.run успешно удален."
        else
            echo "Не удалось удалить файл assistant.run."
        fi
    else
        echo "Файл assistant.run не найден в текущей папке."
    fi

    # Включаем защиту от записи
    echo "Включаем steamos-readonly..."
    run_sudo steamos-readonly enable
    if [ $? -ne 0 ]; then
        echo "Предупреждение: Не удалось включить steamos-readonly"
    fi

    echo "Установка завершена! Ярлык создан на рабочем столе и в меню приложений. В меню пуск находится в разделе Интернет"
    echo "Сервис assistant-resume создан для автоматического перезапуска после сна"
fi

# Очищаем переменную с паролем из памяти
SUDO_PASSWORD=""

echo "========================================="
echo "Скрипт выполнен!"
echo "========================================="
